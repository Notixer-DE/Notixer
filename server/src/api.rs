use crate::openapi::{DocumentedRoutes, ErrorBody};
use axum::{
    Json,
    body::{Body, Bytes},
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use loco_rs::app::AppContext;
use rand::RngCore;
use sea_orm::{
    ConnectionTrait, Database, DatabaseConnection, DatabaseTransaction, DbBackend, DbErr,
    Statement, TransactionTrait, Value,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{fs, io::AsyncWriteExt, sync::Semaphore};
use tokio_util::io::ReaderStream;
use utoipa::ToSchema;
use utoipa_axum::routes;
use uuid::Uuid;

pub const MAX_BLOCK: usize = 4 * 1024 * 1024 + 28;
const MAX_MANIFEST: usize = 64 * 1024;

#[derive(Clone)]
pub struct BlobStore {
    root: PathBuf,
    uploads: Arc<Semaphore>,
}

impl BlobStore {
    pub async fn from_env() -> loco_rs::Result<Self> {
        let root = PathBuf::from(std::env::var("BLOB_DIR").unwrap_or_else(|_| "data/blobs".into()));
        fs::create_dir_all(&root).await?;
        Ok(Self {
            root,
            uploads: Arc::new(Semaphore::new(16)),
        })
    }

    pub(crate) async fn remove_account(&self, account: &str) -> std::io::Result<()> {
        match fs::remove_dir_all(self.root.join(account)).await {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }

    fn path(&self, account: &str, id: &str) -> PathBuf {
        self.root.join(account).join(&id[..2]).join(id)
    }
}

#[derive(Debug)]
pub(crate) struct ApiError(pub(crate) StatusCode);
type ApiResult<T> = Result<T, ApiError>;
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        // Never expose database errors, tokens, manifests or filesystem paths.
        (
            self.0,
            Json(ErrorBody {
                error: self.0.as_u16(),
            }),
        )
            .into_response()
    }
}
impl From<DbErr> for ApiError {
    fn from(e: DbErr) -> Self {
        tracing::error!(error = %e, "database operation failed");
        Self(StatusCode::INTERNAL_SERVER_ERROR)
    }
}
impl From<std::io::Error> for ApiError {
    fn from(_: std::io::Error) -> Self {
        Self(StatusCode::INTERNAL_SERVER_ERROR)
    }
}
fn bad() -> ApiError {
    ApiError(StatusCode::BAD_REQUEST)
}
fn missing() -> ApiError {
    ApiError(StatusCode::NOT_FOUND)
}
fn stmt(sql: &str, values: Vec<Value>) -> Statement {
    Statement::from_sql_and_values(DbBackend::Postgres, sql, values)
}
fn text_array(values: &[String]) -> Value {
    Value::Array(
        sea_orm::sea_query::ArrayType::String,
        Some(Box::new(values.iter().cloned().map(Value::from).collect())),
    )
}
pub(crate) fn new_secret() -> String {
    let mut random = [0u8; 32];
    rand::rng().fill_bytes(&mut random);
    hex::encode(random)
}

pub(crate) fn valid_id(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(crate) struct Identity {
    account: String,
    pub(crate) device: String,
}
pub(crate) async fn authenticate(
    db: &DatabaseConnection,
    headers: &HeaderMap,
) -> ApiResult<Identity> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| v.len() == 64 && valid_id(v))
        .ok_or(ApiError(StatusCode::UNAUTHORIZED))?;
    let hash = hex::encode(Sha256::digest(token.as_bytes()));
    let row = db.query_one_raw(stmt(
        "SELECT account_id::text AS account, id::text AS device FROM devices WHERE token_hash=$1 AND NOT revoked",
        vec![hash.into()],
    )).await?.ok_or(ApiError(StatusCode::UNAUTHORIZED))?;
    Ok(Identity {
        account: row.try_get("", "account")?,
        device: row.try_get("", "device")?,
    })
}

// All writers lock the account row. A cursor is allocated while holding that
// lock until commit, so a reader cannot skip a late-committing lower sequence.
async fn lock_account(db: &DatabaseConnection, who: &Identity) -> ApiResult<DatabaseTransaction> {
    let tx = db.begin().await?;
    tx.execute_unprepared("SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='15s'")
        .await?;
    tx.query_one_raw(stmt(
        "SELECT id FROM accounts WHERE id=$1::uuid FOR UPDATE",
        vec![who.account.clone().into()],
    ))
    .await?
    .ok_or(missing())?;
    let active = tx
        .query_one_raw(stmt(
            "SELECT id FROM devices WHERE id=$1::uuid AND NOT revoked",
            vec![who.device.clone().into()],
        ))
        .await?;
    if active.is_none() {
        return Err(ApiError(StatusCode::UNAUTHORIZED));
    }
    Ok(tx)
}

pub(crate) fn routes() -> DocumentedRoutes {
    DocumentedRoutes::new()
        .add(routes!(health))
        .add(routes!(session))
        .add(routes!(key_check))
        .add(routes!(missing_blobs))
        .add(routes!(upload, download))
        .add(routes!(commit))
        .add(routes!(changes))
        .add(routes!(crate::pairing::redeem))
        .add(routes!(crate::live::create))
        .add(routes!(crate::live::connect, crate::live::end))
        .add(routes!(crate::openapi::json))
}

#[derive(Serialize, ToSchema)]
struct SessionInfo {
    version: u32,
    account: String,
    device: String,
    cursor: i64,
    key_check: Option<String>,
}

#[derive(Serialize, ToSchema)]
struct MissingBlocks {
    missing: Vec<String>,
}

#[derive(Serialize, ToSchema)]
struct ChangesPage {
    cursor: i64,
    #[schema(value_type = Vec<Commit>)]
    items: Vec<serde_json::Value>,
}

#[derive(Serialize, ToSchema)]
#[schema(value_type = String, format = Binary)]
struct EncryptedBlock(Vec<u8>);

#[utoipa::path(
    get, path = "/api/v1/health", tag = "Sync",
    summary = "Check database and blob storage health",
    responses((status = 204, description = "Server ready"), (status = 500, body = crate::openapi::ErrorBody), (status = 503, description = "Server unavailable"))
)]
async fn health(State(ctx): State<AppContext>) -> ApiResult<StatusCode> {
    ctx.db.query_one_raw(stmt("SELECT 1", vec![])).await?;
    let store = ctx
        .shared_store
        .get::<BlobStore>()
        .ok_or(ApiError(StatusCode::SERVICE_UNAVAILABLE))?;
    fs::metadata(&store.root).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[utoipa::path(
    get, path = "/api/v1/session", tag = "Sync",
    summary = "Read the authenticated device session",
    security(("device_token" = [])),
    responses((status = 200, body = SessionInfo), (status = 401, body = crate::openapi::ErrorBody), (status = 404, body = crate::openapi::ErrorBody))
)]
async fn session(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> ApiResult<Json<SessionInfo>> {
    let who = authenticate(&ctx.db, &headers).await?;
    let row = ctx
        .db
        .query_one_raw(stmt(
            "SELECT cursor, key_check FROM accounts WHERE id=$1::uuid",
            vec![who.account.clone().into()],
        ))
        .await?
        .ok_or(missing())?;
    Ok(Json(SessionInfo {
        version: 1,
        account: who.account,
        device: who.device,
        cursor: row.try_get("", "cursor")?,
        key_check: row.try_get("", "key_check")?,
    }))
}

#[derive(Deserialize, ToSchema)]
struct KeyCheck {
    #[schema(pattern = "^[a-f0-9]{64}$")]
    value: String,
}
#[utoipa::path(
    put, path = "/api/v1/key-check", tag = "Sync",
    summary = "Initialize or verify the recovery key check",
    security(("device_token" = [])),
    request_body = KeyCheck,
    responses((status = 204, description = "Recovery key check matches"), (status = 400, body = crate::openapi::ErrorBody), (status = 401, body = crate::openapi::ErrorBody), (status = 409, description = "Recovery key check conflicts", body = crate::openapi::ErrorBody))
)]
async fn key_check(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Json(body): Json<KeyCheck>,
) -> ApiResult<StatusCode> {
    if !valid_id(&body.value) {
        return Err(bad());
    }
    let who = authenticate(&ctx.db, &headers).await?;
    let tx = lock_account(&ctx.db, &who).await?;
    let row = tx.query_one_raw(stmt(
        "UPDATE accounts SET key_check=COALESCE(key_check,$2) WHERE id=$1::uuid RETURNING key_check",
        vec![who.account.into(), body.value.clone().into()],
    )).await?.ok_or(missing())?;
    if row.try_get::<String>("", "key_check")? != body.value {
        return Err(ApiError(StatusCode::CONFLICT));
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize, ToSchema)]
struct BlockQuery {
    #[schema(max_items = 64)]
    ids: Vec<String>,
}
#[utoipa::path(
    post, path = "/api/v1/blobs/missing", tag = "Blocks",
    summary = "Find which encrypted blocks need uploading",
    security(("device_token" = [])),
    request_body = BlockQuery,
    responses((status = 200, body = MissingBlocks), (status = 400, body = crate::openapi::ErrorBody), (status = 401, body = crate::openapi::ErrorBody))
)]
async fn missing_blobs(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    bytes: Bytes,
) -> ApiResult<Json<MissingBlocks>> {
    if bytes.len() > 8192 {
        return Err(bad());
    }
    let body: BlockQuery = serde_json::from_slice(&bytes).map_err(|_| bad())?;
    if body.ids.len() > 64 || body.ids.iter().any(|id| !valid_id(id)) {
        return Err(bad());
    }
    let who = authenticate(&ctx.db, &headers).await?;
    // One query, not one round trip for every block.
    let rows = ctx
        .db
        .query_all_raw(stmt(
            "SELECT id FROM blobs WHERE account_id=$1::uuid AND id=ANY($2::text[])",
            vec![who.account.into(), text_array(&body.ids)],
        ))
        .await?;
    let present = rows
        .into_iter()
        .map(|row| row.try_get::<String>("", "id"))
        .collect::<Result<std::collections::HashSet<_>, _>>()?;
    Ok(Json(MissingBlocks {
        missing: body
            .ids
            .into_iter()
            .filter(|id| !present.contains(id))
            .collect(),
    }))
}

#[utoipa::path(
    put, path = "/api/v1/blobs/{id}", tag = "Blocks",
    summary = "Upload an encrypted block",
    security(("device_token" = [])),
    params(("id" = String, Path, description = "SHA-256 block identifier")),
    request_body(content = EncryptedBlock, content_type = "application/octet-stream", description = "28 to 4194332 bytes"),
    responses((status = 201, description = "Block stored"), (status = 204, description = "Block already present"), (status = 400, body = crate::openapi::ErrorBody), (status = 401, body = crate::openapi::ErrorBody), (status = 429, body = crate::openapi::ErrorBody), (status = 507, description = "Storage quota exceeded", body = crate::openapi::ErrorBody))
)]
async fn upload(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(id): Path<String>,
    bytes: Bytes,
) -> ApiResult<StatusCode> {
    if !valid_id(&id)
        || bytes.len() < 28
        || bytes.len() > MAX_BLOCK
        || hex::encode(Sha256::digest(&bytes)) != id
    {
        return Err(bad());
    }
    let who = authenticate(&ctx.db, &headers).await?;
    let store = ctx
        .shared_store
        .get::<BlobStore>()
        .ok_or(ApiError(StatusCode::SERVICE_UNAVAILABLE))?;
    let _permit = store
        .uploads
        .try_acquire()
        .map_err(|_| ApiError(StatusCode::TOO_MANY_REQUESTS))?;
    let path = store.path(&who.account, &id);
    let tx = lock_account(&ctx.db, &who).await?;
    if tx
        .query_one_raw(stmt(
            "SELECT id FROM blobs WHERE account_id=$1::uuid AND id=$2",
            vec![who.account.clone().into(), id.clone().into()],
        ))
        .await?
        .is_some()
    {
        tx.commit().await?;
        return Ok(StatusCode::NO_CONTENT);
    }
    let available = tx.execute_raw(stmt(
        "UPDATE accounts SET used_bytes=used_bytes+$2 WHERE id=$1::uuid AND used_bytes+$2<=quota_bytes",
        vec![who.account.clone().into(), (bytes.len() as i64).into()],
    )).await?.rows_affected();
    if available != 1 {
        return Err(ApiError(StatusCode::INSUFFICIENT_STORAGE));
    }
    fs::create_dir_all(path.parent().unwrap()).await?;
    let tmp = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
    // Complete and fsync before making the block available to commits.
    let result = async {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .await?;
        file.write_all(&bytes).await?;
        file.sync_all().await?;
        drop(file);
        fs::rename(&tmp, &path).await?;
        let root = store.root.clone();
        let parent = path.parent().unwrap().to_path_buf();
        tokio::task::spawn_blocking(move || {
            // Newly created account/prefix directories must also survive a crash.
            let mut current = parent.as_path();
            loop {
                std::fs::File::open(current)?.sync_all()?;
                if current == root {
                    break;
                }
                current = current
                    .parent()
                    .ok_or_else(|| std::io::Error::other("invalid blob root"))?;
            }
            Ok::<(), std::io::Error>(())
        })
        .await
        .map_err(std::io::Error::other)??;
        Ok::<(), std::io::Error>(())
    }
    .await;
    if result.is_err() {
        let _ = fs::remove_file(&tmp).await;
    }
    result?;
    tx.execute_raw(stmt(
        "INSERT INTO blobs(account_id,id,bytes) VALUES($1::uuid,$2,$3)",
        vec![who.account.into(), id.into(), (bytes.len() as i64).into()],
    ))
    .await?;
    tx.commit().await?;
    Ok(StatusCode::CREATED)
}

#[utoipa::path(
    get, path = "/api/v1/blobs/{id}", tag = "Blocks",
    summary = "Download an encrypted block",
    security(("device_token" = [])),
    params(("id" = String, Path, description = "SHA-256 block identifier")),
    responses((status = 200, body = EncryptedBlock, content_type = "application/octet-stream"), (status = 400, body = crate::openapi::ErrorBody), (status = 401, body = crate::openapi::ErrorBody), (status = 404, body = crate::openapi::ErrorBody))
)]
async fn download(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    if !valid_id(&id) {
        return Err(bad());
    }
    let who = authenticate(&ctx.db, &headers).await?;
    let row = ctx
        .db
        .query_one_raw(stmt(
            "SELECT bytes FROM blobs WHERE account_id=$1::uuid AND id=$2",
            vec![who.account.clone().into(), id.clone().into()],
        ))
        .await?
        .ok_or(missing())?;
    let store = ctx
        .shared_store
        .get::<BlobStore>()
        .ok_or(ApiError(StatusCode::SERVICE_UNAVAILABLE))?;
    let file = fs::File::open(store.path(&who.account, &id)).await?;
    Ok((
        [
            ("content-type", "application/octet-stream".to_string()),
            (
                "content-length",
                row.try_get::<i64>("", "bytes")?.to_string(),
            ),
            ("cache-control", "no-store".into()),
        ],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response())
}

#[derive(Debug, Deserialize, Serialize, Clone, ToSchema)]
#[serde(deny_unknown_fields)]
struct Commit {
    #[schema(pattern = "^[a-f0-9]{64}$")]
    id: String,
    #[schema(max_items = 512)]
    parents: Vec<String>,
    #[schema(max_items = 64)]
    blobs: Vec<String>,
    #[schema(format = Byte, max_length = 65536)]
    manifest: String,
}
impl Commit {
    fn validate(&self) -> ApiResult<()> {
        if !valid_id(&self.id)
            || self.parents.len() > 512
            || self.blobs.len() > 64
            || self.parents.iter().any(|v| !valid_id(v) || v == &self.id)
            || self.blobs.iter().any(|v| !valid_id(v))
            || self.manifest.len() > MAX_MANIFEST
            || STANDARD
                .decode(&self.manifest)
                .map_or(true, |v| v.len() < 28)
        {
            return Err(bad());
        }
        Ok(())
    }
}
#[utoipa::path(
    post, path = "/api/v1/commits", tag = "Sync",
    summary = "Publish or replay an encrypted revision",
    security(("device_token" = [])),
    request_body = Commit,
    responses((status = 200, body = Commit), (status = 400, body = crate::openapi::ErrorBody), (status = 401, body = crate::openapi::ErrorBody), (status = 413, body = crate::openapi::ErrorBody), (status = 507, description = "Revision quota exceeded", body = crate::openapi::ErrorBody))
)]
async fn commit(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    bytes: Bytes,
) -> ApiResult<Json<serde_json::Value>> {
    if bytes.len() > 128 * 1024 {
        return Err(ApiError(StatusCode::PAYLOAD_TOO_LARGE));
    }
    let body: Commit = serde_json::from_slice(&bytes).map_err(|_| bad())?;
    body.validate()?;
    let who = authenticate(&ctx.db, &headers).await?;
    let tx = lock_account(&ctx.db, &who).await?;
    if let Some(row) = tx
        .query_one_raw(stmt(
            "SELECT envelope FROM revisions WHERE account_id=$1::uuid AND id=$2",
            vec![who.account.clone().into(), body.id.clone().into()],
        ))
        .await?
    {
        // The immutable first commit is canonical. Clients must use its manifest,
        // not a newly encrypted candidate with different random nonces.
        return Ok(Json(row.try_get("", "envelope")?));
    }
    let parent_count = tx.query_one_raw(stmt(
        "SELECT count(*) AS count FROM revisions WHERE account_id=$1::uuid AND id=ANY($2::text[])",
        vec![who.account.clone().into(), text_array(&body.parents)],
    )).await?.ok_or(bad())?.try_get::<i64>("", "count")?;
    if parent_count != body.parents.len() as i64 {
        return Err(bad());
    }
    let mut total = 0i64;
    let store = ctx
        .shared_store
        .get::<BlobStore>()
        .ok_or(ApiError(StatusCode::SERVICE_UNAVAILABLE))?;
    let rows = tx
        .query_all_raw(stmt(
            "SELECT id,bytes FROM blobs WHERE account_id=$1::uuid AND id=ANY($2::text[])",
            vec![who.account.clone().into(), text_array(&body.blobs)],
        ))
        .await?;
    let sizes = rows
        .into_iter()
        .map(|row| {
            Ok((
                row.try_get::<String>("", "id")?,
                row.try_get::<i64>("", "bytes")?,
            ))
        })
        .collect::<Result<std::collections::HashMap<_, _>, DbErr>>()?;
    for blob in &body.blobs {
        let bytes = *sizes.get(blob).ok_or(bad())?;
        let metadata = fs::metadata(store.path(&who.account, blob))
            .await
            .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE))?;
        if metadata.len() != bytes as u64 {
            return Err(ApiError(StatusCode::SERVICE_UNAVAILABLE));
        }
        total += bytes;
    }
    if total > 256 * 1024 * 1024 + 64 * 28 {
        return Err(bad());
    }
    let row = tx.query_one_raw(stmt(
        "UPDATE accounts SET cursor=cursor+1, revision_count=revision_count+1, used_bytes=used_bytes+$2 WHERE id=$1::uuid AND revision_count<max_revisions AND key_check IS NOT NULL AND used_bytes+$2<=quota_bytes RETURNING cursor",
        vec![who.account.clone().into(), (bytes.len() as i64).into()],
    )).await?.ok_or(ApiError(StatusCode::INSUFFICIENT_STORAGE))?;
    let envelope = serde_json::to_value(&body).map_err(|_| bad())?;
    tx.execute_raw(stmt("INSERT INTO revisions(account_id,id,seq,envelope,device_id) VALUES($1::uuid,$2,$3,$4,$5::uuid)",
        vec![who.account.clone().into(), body.id.clone().into(), row.try_get::<i64>("", "cursor")?.into(),
            envelope.clone().into(), who.device.into()])).await?;
    tx.execute_raw(stmt(
        "INSERT INTO revision_blobs(account_id,revision_id,blob_id) SELECT $1::uuid,$2,unnest($3::text[]) ON CONFLICT DO NOTHING",
        vec![who.account.into(), body.id.into(), text_array(&body.blobs)],
    )).await?;
    tx.commit().await?;
    Ok(Json(envelope))
}

#[derive(Deserialize)]
struct Changes {
    #[serde(default)]
    after: i64,
}
#[utoipa::path(
    get, path = "/api/v1/changes", tag = "Sync",
    summary = "List up to 100 revisions after a cursor",
    security(("device_token" = [])),
    params(("after" = Option<i64>, Query, minimum = 0, description = "Last processed cursor, defaults to zero")),
    responses((status = 200, body = ChangesPage), (status = 400, body = crate::openapi::ErrorBody), (status = 401, body = crate::openapi::ErrorBody), (status = 409, description = "Cursor is ahead of the account", body = crate::openapi::ErrorBody))
)]
async fn changes(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Query(query): Query<Changes>,
) -> ApiResult<Json<ChangesPage>> {
    if query.after < 0 {
        return Err(bad());
    }
    let who = authenticate(&ctx.db, &headers).await?;
    let row = ctx
        .db
        .query_one_raw(stmt(
            "SELECT cursor FROM accounts WHERE id=$1::uuid",
            vec![who.account.clone().into()],
        ))
        .await?
        .ok_or(missing())?;
    if query.after > row.try_get::<i64>("", "cursor")? {
        return Err(ApiError(StatusCode::CONFLICT));
    }
    let rows = ctx.db.query_all_raw(stmt(
        "SELECT seq,envelope FROM revisions WHERE account_id=$1::uuid AND seq>$2 ORDER BY seq LIMIT 100",
        vec![who.account.into(), query.after.into()],
    )).await?;
    let mut cursor = query.after;
    let mut items = vec![];
    for row in rows {
        cursor = row.try_get("", "seq")?;
        items.push(row.try_get::<serde_json::Value>("", "envelope")?);
    }
    Ok(Json(ChangesPage { cursor, items }))
}

pub async fn admin() -> loco_rs::Result<()> {
    let db = Database::connect(
        std::env::var("DATABASE_URL")
            .map_err(|_| loco_rs::Error::Message("DATABASE_URL required".into()))?,
    )
    .await?;
    let args: Vec<String> = std::env::args().skip(2).collect();
    match args.first().map(String::as_str) {
        Some("init-admin") if args.len() == 1 => {
            // Generate the first administrator's credentials locally and display them once.
            // Never replace an existing account or expose credentials over HTTP.
            let existing = db
                .query_one_raw(stmt("SELECT username FROM admin_users LIMIT 1", vec![]))
                .await?;
            if existing.is_some() {
                return Err(loco_rs::Error::Message(
                    "An administrator already exists; refusing to overwrite credentials".into(),
                ));
            }

            let mut random = [0u8; 32];
            rand::rng().fill_bytes(&mut random);
            let password = hex::encode(random);
            let hash = crate::admin::hash_password(&password).map_err(loco_rs::Error::Message)?;
            let inserted = db.query_one_raw(stmt(
                "INSERT INTO admin_users(username, password_hash) VALUES($1, $2) ON CONFLICT (username) DO NOTHING RETURNING username",
                vec!["admin".into(), hash.into()],
            )).await?;
            if inserted.is_none() {
                return Err(loco_rs::Error::Message(
                    "Administrator already exists; refusing to overwrite credentials".into(),
                ));
            }
            println!("Admin username: admin");
            println!("Admin password (shown once; store securely): {password}");
        }
        Some("create-account") => {
            let id = Uuid::new_v4().to_string();
            db.execute_raw(stmt(
                "INSERT INTO accounts(id) VALUES($1::uuid)",
                vec![id.clone().into()],
            ))
            .await?;
            println!("Account: {id}");
        }
        Some("add-device") if args.len() == 2 => {
            let account = Uuid::parse_str(&args[1])
                .map_err(|_| loco_rs::Error::Message("Invalid account UUID".into()))?;
            let mut random = [0u8; 32];
            rand::rng().fill_bytes(&mut random);
            let token = hex::encode(random);
            let id = Uuid::new_v4().to_string();
            db.execute_raw(stmt(
                "INSERT INTO devices(id,account_id,token_hash) VALUES($1::uuid,$2::uuid,$3)",
                vec![
                    id.clone().into(),
                    account.to_string().into(),
                    hex::encode(Sha256::digest(token.as_bytes())).into(),
                ],
            ))
            .await?;
            println!("Device: {id}\nToken (store securely; shown once): {token}");
        }
        Some("revoke-device") if args.len() == 2 => {
            let id = Uuid::parse_str(&args[1])
                .map_err(|_| loco_rs::Error::Message("Invalid device UUID".into()))?;
            // Serialize with ongoing writes.
            let tx = db.begin().await?;
            tx.query_one_raw(stmt("SELECT a.id FROM accounts a JOIN devices d ON d.account_id=a.id WHERE d.id=$1::uuid FOR UPDATE OF a",
                vec![id.to_string().into()])).await?;
            tx.execute_raw(stmt(
                "UPDATE devices SET revoked=true WHERE id=$1::uuid",
                vec![id.to_string().into()],
            ))
            .await?;
            tx.commit().await?;
            println!("Device revoked. This does not rotate the vault key.");
        }
        _ => {
            return Err(loco_rs::Error::Message(
                "Usage: admin init-admin | create-account | add-device ACCOUNT_UUID | revoke-device DEVICE_UUID"
                    .into(),
            ));
        }
    }
    db.close().await?;
    tokio::time::sleep(Duration::from_millis(10)).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identifiers_cannot_escape_storage() {
        for id in [
            "../secret",
            "",
            &"A".repeat(64),
            &"a".repeat(63),
            &"é".repeat(32),
        ] {
            assert!(!valid_id(id));
        }
        assert!(valid_id(&"a".repeat(64)));
    }
    #[test]
    fn rejects_unbounded_or_invalid_commits() {
        let mut c = Commit {
            id: "a".repeat(64),
            parents: vec![],
            blobs: vec![],
            manifest: STANDARD.encode([0; 28]),
        };
        assert!(c.validate().is_ok());
        c.parents.push(c.id.clone());
        assert!(c.validate().is_err());
        c.parents.clear();
        c.blobs = vec!["b".repeat(64); 65];
        assert!(c.validate().is_err());
    }
}
