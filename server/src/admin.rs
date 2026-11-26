use crate::api::new_secret;
use crate::openapi::{ApiStatus, DeviceToken, DocumentedRoutes};
use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use loco_rs::app::AppContext;
use rand::RngCore;
use sea_orm::{ConnectionTrait, DatabaseConnection, DbBackend, Statement, TransactionTrait};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
use utoipa::ToSchema;
use utoipa_axum::routes;
use uuid::Uuid;

static PASSWORD_WORK: Semaphore = Semaphore::const_new(2);

async fn password_work<T: Send + 'static>(
    action: impl FnOnce() -> T + Send + 'static,
) -> Result<T, StatusCode> {
    let permit = PASSWORD_WORK
        .try_acquire()
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        action()
    })
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

fn secure_cookie(headers: &HeaderMap) -> &'static str {
    if headers
        .get("x-forwarded-proto")
        .is_some_and(|value| value == "https")
    {
        "; Secure"
    } else {
        ""
    }
}

pub fn hash_password(password: &str) -> Result<String, String> {
    let argon2 = Argon2::default();
    let mut salt_bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut salt_bytes);
    let salt = SaltString::encode_b64(&salt_bytes).map_err(|e| e.to_string())?;
    argon2
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    let Ok(parsed_hash) = PasswordHash::new(hash) else {
        return false;
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed_hash)
        .is_ok()
}

pub(crate) fn routes() -> DocumentedRoutes {
    DocumentedRoutes::new()
        .asset("/admin", get(crate::admin_assets::index))
        .asset("/admin/assets/admin.js", get(crate::admin_assets::script))
        .asset(
            "/admin/assets/admin.css",
            get(crate::admin_assets::stylesheet),
        )
        .add(routes!(me))
        .add(routes!(login))
        .add(routes!(logout))
        .add(routes!(change_password))
        .add(routes!(list_accounts, create_account))
        .add(routes!(delete_account))
        .add(routes!(add_device))
        .add(routes!(crate::pairing::create))
        .add(routes!(revoke_device))
        .add(routes!(unrevoke_device))
}

#[derive(Serialize, ToSchema)]
struct AdminIdentity {
    authenticated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    username: Option<String>,
}

#[derive(Serialize, ToSchema)]
struct AdminLogin {
    ok: bool,
    username: String,
}

#[derive(Serialize, ToSchema)]
struct CreatedAccount {
    id: Uuid,
}

#[derive(Serialize, Deserialize, ToSchema)]
struct AdminDevice {
    id: Uuid,
    revoked: bool,
    #[schema(format = DateTime)]
    created_at: String,
}

#[derive(Serialize, ToSchema)]
struct AdminAccount {
    id: Uuid,
    cursor: i64,
    used_bytes: i64,
    quota_bytes: i64,
    revision_count: i64,
    max_revisions: i64,
    needs_key: bool,
    devices: Vec<AdminDevice>,
}

fn get_session_hash(headers: &HeaderMap) -> Option<String> {
    let cookie_header = headers.get(header::COOKIE)?.to_str().ok()?;
    for cookie in cookie_header.split(';') {
        if let Some(("noter_admin_session", token)) = cookie.trim().split_once('=')
            && crate::api::valid_id(token)
        {
            return Some(hex::encode(Sha256::digest(token.as_bytes())));
        }
    }
    None
}

pub(crate) async fn authenticate_admin(
    db: &DatabaseConnection,
    headers: &HeaderMap,
) -> Result<String, StatusCode> {
    let token = get_session_hash(headers).ok_or(StatusCode::UNAUTHORIZED)?;
    let row = db
        .query_one_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "SELECT username FROM admin_sessions WHERE token_hash=$1 AND expires_at > now()",
            vec![token.into()],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::UNAUTHORIZED)?;
    let username: String = row
        .try_get("", "username")
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(username)
}

#[utoipa::path(
    get, path = "/admin/api/me", tag = "Administration",
    summary = "Check the current admin session",
    responses((status = 200, body = AdminIdentity), (status = 500, description = "Could not read session"))
)]
async fn me(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Json<AdminIdentity>, StatusCode> {
    match authenticate_admin(&ctx.db, &headers).await {
        Ok(username) => Ok(Json(AdminIdentity {
            authenticated: true,
            username: Some(username),
        })),
        Err(StatusCode::UNAUTHORIZED) => Ok(Json(AdminIdentity {
            authenticated: false,
            username: None,
        })),
        Err(error) => Err(error),
    }
}

#[derive(Deserialize, ToSchema)]
struct LoginRequest {
    username: String,
    #[schema(format = Password)]
    password: String,
}

#[utoipa::path(
    post, path = "/admin/api/login", tag = "Administration",
    summary = "Sign in and receive the admin cookie",
    request_body = LoginRequest,
    responses((status = 200, body = AdminLogin, headers(("Set-Cookie" = String, description = "Admin session cookie"))), (status = 401, description = "Invalid credentials"), (status = 503, description = "Login capacity reached"))
)]
async fn login(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Json(payload): Json<LoginRequest>,
) -> Result<Response, StatusCode> {
    if payload.username.len() > 128 || payload.password.len() > 1024 {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let row = ctx
        .db
        .query_one_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "SELECT password_hash FROM admin_users WHERE username=$1",
            vec![payload.username.clone().into()],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::UNAUTHORIZED)?;

    let hash: String = row
        .try_get("", "password_hash")
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let verify_hash = hash.clone();
    if !password_work(move || verify_password(&payload.password, &verify_hash)).await? {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let session_token = new_secret();

    let session = ctx
        .db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "WITH expired AS (DELETE FROM admin_sessions WHERE expires_at <= now()),
            account AS (
                SELECT username FROM admin_users WHERE username=$2 AND password_hash=$3 FOR UPDATE
            )
            INSERT INTO admin_sessions(token_hash, username, expires_at)
            SELECT $1, username, now() + interval '7 days' FROM account",
            vec![
                hex::encode(Sha256::digest(session_token.as_bytes())).into(),
                payload.username.clone().into(),
                hash.into(),
            ],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if session.rows_affected() != 1 {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let cookie_val = format!(
        "noter_admin_session={session_token}; Path=/admin; HttpOnly; SameSite=Strict; Max-Age={}{}",
        7 * 24 * 3600,
        secure_cookie(&headers),
    );

    let mut headers = HeaderMap::new();
    headers.insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&cookie_val).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
    );

    Ok((
        headers,
        Json(AdminLogin {
            ok: true,
            username: payload.username,
        }),
    )
        .into_response())
}

#[utoipa::path(
    post, path = "/admin/api/logout", tag = "Administration",
    summary = "End the current admin session",
    responses((status = 200, body = ApiStatus, headers(("Set-Cookie" = String, description = "Clears the admin session cookie"))))
)]
async fn logout(State(ctx): State<AppContext>, headers: HeaderMap) -> Result<Response, StatusCode> {
    if let Some(token) = get_session_hash(&headers) {
        ctx.db
            .execute_raw(Statement::from_sql_and_values(
                DbBackend::Postgres,
                "DELETE FROM admin_sessions WHERE token_hash=$1",
                vec![token.into()],
            ))
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    let mut resp_headers = HeaderMap::new();
    resp_headers.insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&format!(
            "noter_admin_session=; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=0{}",
            secure_cookie(&headers),
        ))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
    );

    Ok((resp_headers, Json(ApiStatus { ok: true })).into_response())
}

#[derive(Deserialize, ToSchema)]
struct ChangePasswordRequest {
    #[schema(format = Password)]
    current_password: String,
    #[schema(format = Password, min_length = 12, max_length = 1024)]
    new_password: String,
}

#[utoipa::path(
    post, path = "/admin/api/change-password", tag = "Administration",
    summary = "Change the admin password",
    security(("admin_session" = [])),
    request_body = ChangePasswordRequest,
    responses((status = 200, body = ApiStatus), (status = 400, description = "Password length is invalid"), (status = 401, description = "Admin session or current password invalid"), (status = 409, description = "Password changed concurrently"))
)]
async fn change_password(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<Json<ApiStatus>, StatusCode> {
    let username = authenticate_admin(&ctx.db, &headers).await?;

    if payload.current_password.len() > 1024
        || payload.new_password.len() > 1024
        || payload.new_password.trim().len() < 12
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    let row = ctx
        .db
        .query_one_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "SELECT password_hash FROM admin_users WHERE username=$1",
            vec![username.clone().into()],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;

    let current_hash: String = row
        .try_get("", "password_hash")
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let verify_hash = current_hash.clone();
    let new_hash = password_work(move || {
        if !verify_password(&payload.current_password, &verify_hash) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        hash_password(&payload.new_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
    })
    .await??;
    let session = get_session_hash(&headers).ok_or(StatusCode::UNAUTHORIZED)?;
    let tx = ctx
        .db
        .begin()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let updated = tx
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "UPDATE admin_users SET password_hash=$1 WHERE username=$2 AND password_hash=$3",
            vec![
                new_hash.into(),
                username.clone().into(),
                current_hash.into(),
            ],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if updated.rows_affected() != 1 {
        return Err(StatusCode::CONFLICT);
    }
    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "DELETE FROM admin_sessions WHERE username=$1 AND token_hash <> $2",
        vec![username.into(), session.into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tx.commit()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(ApiStatus { ok: true }))
}

#[utoipa::path(
    get, path = "/admin/api/accounts", tag = "Administration",
    summary = "List accounts, usage and devices",
    security(("admin_session" = [])),
    responses((status = 200, body = Vec<AdminAccount>), (status = 401, description = "Admin sign-in required"))
)]
async fn list_accounts(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Json<Vec<AdminAccount>>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let rows = ctx
        .db
        .query_all_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            r#"
            SELECT 
                a.id::text AS id,
                a.cursor,
                a.used_bytes,
                a.quota_bytes,
                a.revision_count,
                a.max_revisions,
                a.key_check IS NOT NULL AS needs_key,
                COALESCE(
                    json_agg(
                        json_build_object(
                            'id', d.id::text,
                            'revoked', d.revoked,
                            'created_at', d.created_at
                        ) ORDER BY d.created_at DESC
                    ) FILTER (WHERE d.id IS NOT NULL),
                    '[]'::json
                ) AS devices
            FROM accounts a
            LEFT JOIN devices d ON d.account_id = a.id
            GROUP BY a.id
            ORDER BY a.cursor DESC, a.id ASC
            "#,
            vec![],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut accounts = Vec::new();
    for row in rows {
        let id: String = row
            .try_get("", "id")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let cursor: i64 = row
            .try_get("", "cursor")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let used_bytes: i64 = row
            .try_get("", "used_bytes")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let quota_bytes: i64 = row
            .try_get("", "quota_bytes")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let revision_count: i64 = row
            .try_get("", "revision_count")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let max_revisions: i64 = row
            .try_get("", "max_revisions")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let needs_key: bool = row
            .try_get("", "needs_key")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let devices: serde_json::Value = row
            .try_get("", "devices")
            .unwrap_or_else(|_| serde_json::json!([]));

        accounts.push(AdminAccount {
            id: Uuid::parse_str(&id).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
            cursor,
            used_bytes,
            quota_bytes,
            revision_count,
            max_revisions,
            needs_key,
            devices: serde_json::from_value(devices)
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
        });
    }

    Ok(Json(accounts))
}

#[utoipa::path(
    post, path = "/admin/api/accounts", tag = "Administration",
    summary = "Create an account",
    security(("admin_session" = [])),
    responses((status = 200, body = CreatedAccount), (status = 401, description = "Admin sign-in required"))
)]
async fn create_account(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Json<CreatedAccount>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let id = Uuid::new_v4();
    ctx.db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "INSERT INTO accounts(id) VALUES($1::uuid)",
            vec![id.to_string().into()],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(CreatedAccount { id }))
}

#[utoipa::path(
    delete, path = "/admin/api/accounts/{id}", tag = "Administration",
    summary = "Permanently delete an account and its data",
    security(("admin_session" = [])), params(("id" = Uuid, Path, description = "Account or device UUID")),
    responses((status = 200, body = ApiStatus), (status = 400, description = "Invalid account ID"), (status = 401, description = "Admin sign-in required"), (status = 404, description = "Resource not found"))
)]
async fn delete_account(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(account_id): Path<String>,
) -> Result<Json<ApiStatus>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;
    let account_id = Uuid::parse_str(&account_id)
        .map_err(|_| StatusCode::BAD_REQUEST)?
        .to_string();

    let tx = ctx
        .db
        .begin()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Use the same account lock as uploads, commits and device enrolment.
    tx.query_one_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "SELECT id FROM accounts WHERE id=$1::uuid FOR UPDATE",
        vec![account_id.clone().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    .ok_or(StatusCode::NOT_FOUND)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "DELETE FROM revision_blobs WHERE account_id = $1::uuid",
        vec![account_id.clone().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "DELETE FROM revisions WHERE account_id = $1::uuid",
        vec![account_id.clone().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "DELETE FROM blobs WHERE account_id = $1::uuid",
        vec![account_id.clone().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "DELETE FROM devices WHERE account_id = $1::uuid",
        vec![account_id.clone().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "DELETE FROM accounts WHERE id = $1::uuid",
        vec![account_id.clone().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.commit()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if let Some(rooms) = ctx.shared_store.get::<crate::live::LiveRooms>() {
        rooms.end_account(&account_id).await;
    }

    if let Some(store) = ctx.shared_store.get::<crate::api::BlobStore>() {
        store.remove_account(&account_id).await.map_err(|error| {
            tracing::error!(%error, "could not remove deleted account blobs");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    }

    Ok(Json(ApiStatus { ok: true }))
}

#[utoipa::path(
    post, path = "/admin/api/accounts/{id}/devices", tag = "Administration",
    summary = "Create a device and return its access token once",
    security(("admin_session" = [])), params(("id" = Uuid, Path, description = "Account or device UUID")),
    responses((status = 200, body = DeviceToken), (status = 400, description = "Invalid account ID"), (status = 401, description = "Admin sign-in required"), (status = 404, description = "Resource not found"))
)]
async fn add_device(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(account_id): Path<String>,
) -> Result<Json<DeviceToken>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let account = Uuid::parse_str(&account_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let token = new_secret();
    let device_id = Uuid::new_v4();
    let token_hash = hex::encode(Sha256::digest(token.as_bytes()));

    let inserted = ctx.db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "INSERT INTO devices(id, account_id, token_hash) SELECT $1::uuid, id, $3 FROM accounts WHERE id=$2::uuid",
            vec![
                device_id.to_string().into(),
                account.to_string().into(),
                token_hash.into(),
            ],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    if inserted.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(DeviceToken {
        id: device_id,
        token,
    }))
}

#[utoipa::path(
    post, path = "/admin/api/devices/{id}/revoke", tag = "Administration",
    summary = "Revoke a device token",
    security(("admin_session" = [])), params(("id" = Uuid, Path, description = "Account or device UUID")),
    responses((status = 200, body = ApiStatus), (status = 400, description = "Invalid device ID"), (status = 401, description = "Admin sign-in required"), (status = 404, description = "Resource not found"))
)]
async fn revoke_device(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<ApiStatus>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let id = Uuid::parse_str(&device_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let tx = ctx
        .db
        .begin()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tx.query_one_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "SELECT a.id FROM accounts a JOIN devices d ON d.account_id=a.id WHERE d.id=$1::uuid FOR UPDATE OF a",
        vec![id.to_string().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    .ok_or(StatusCode::NOT_FOUND)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "UPDATE devices SET revoked=true WHERE id=$1::uuid",
        vec![id.to_string().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.commit()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if let Some(rooms) = ctx.shared_store.get::<crate::live::LiveRooms>() {
        rooms.end_device(&id.to_string()).await;
    }

    Ok(Json(ApiStatus { ok: true }))
}

#[utoipa::path(
    post, path = "/admin/api/devices/{id}/unrevoke", tag = "Administration",
    summary = "Restore a device token",
    security(("admin_session" = [])), params(("id" = Uuid, Path, description = "Account or device UUID")),
    responses((status = 200, body = ApiStatus), (status = 400, description = "Invalid device ID"), (status = 401, description = "Admin sign-in required"), (status = 404, description = "Resource not found"))
)]
async fn unrevoke_device(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<ApiStatus>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let id = Uuid::parse_str(&device_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let tx = ctx
        .db
        .begin()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tx.query_one_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "SELECT a.id FROM accounts a JOIN devices d ON d.account_id=a.id WHERE d.id=$1::uuid FOR UPDATE OF a",
        vec![id.to_string().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    .ok_or(StatusCode::NOT_FOUND)?;

    tx.execute_raw(Statement::from_sql_and_values(
        DbBackend::Postgres,
        "UPDATE devices SET revoked=false WHERE id=$1::uuid",
        vec![id.to_string().into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    tx.commit()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(ApiStatus { ok: true }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_hashes_and_verifies() {
        let password = "a sample password";
        let hash = hash_password(password).expect("hashing failed");
        assert!(verify_password(password, &hash));
        assert!(!verify_password("wrong", &hash));
    }
}
