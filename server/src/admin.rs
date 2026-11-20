use crate::api::new_secret;
use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use loco_rs::{app::AppContext, controller::Routes};
use rand::RngCore;
use sea_orm::{ConnectionTrait, DatabaseConnection, DbBackend, Statement, TransactionTrait};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
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

pub fn routes() -> Routes {
    Routes::new()
        .prefix("admin")
        .add("/", get(crate::admin_assets::index))
        .add("/assets/admin.js", get(crate::admin_assets::script))
        .add("/assets/admin.css", get(crate::admin_assets::stylesheet))
        .add("/api/me", get(me))
        .add("/api/login", post(login))
        .add("/api/logout", post(logout))
        .add("/api/change-password", post(change_password))
        .add("/api/accounts", get(list_accounts).post(create_account))
        .add("/api/accounts/{id}", delete(delete_account))
        .add("/api/accounts/{id}/devices", post(add_device))
        .add("/api/accounts/{id}/pairing", post(crate::pairing::create))
        .add("/api/devices/{id}/revoke", post(revoke_device))
        .add("/api/devices/{id}/unrevoke", post(unrevoke_device))
}

fn get_session_token(headers: &HeaderMap) -> Option<String> {
    let cookie_header = headers.get(header::COOKIE)?.to_str().ok()?;
    for cookie in cookie_header.split(';') {
        if let Some(("noter_admin_session", token)) = cookie.trim().split_once('=')
            && !token.is_empty()
        {
            return Some(token.to_string());
        }
    }
    None
}

pub(crate) async fn authenticate_admin(
    db: &DatabaseConnection,
    headers: &HeaderMap,
) -> Result<String, StatusCode> {
    let token = get_session_token(headers).ok_or(StatusCode::UNAUTHORIZED)?;
    let row = db
        .query_one_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "SELECT username FROM admin_sessions WHERE token=$1 AND expires_at > now()",
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

async fn me(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    match authenticate_admin(&ctx.db, &headers).await {
        Ok(username) => Ok(Json(serde_json::json!({
            "authenticated": true,
            "username": username
        }))),
        Err(StatusCode::UNAUTHORIZED) => Ok(Json(serde_json::json!({
            "authenticated": false
        }))),
        Err(error) => Err(error),
    }
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

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
            "WITH account AS (
                SELECT username FROM admin_users WHERE username=$2 AND password_hash=$3 FOR UPDATE
            )
            INSERT INTO admin_sessions(token, username, expires_at)
            SELECT $1, username, now() + interval '7 days' FROM account",
            vec![
                session_token.clone().into(),
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
        Json(serde_json::json!({
            "ok": true,
            "username": payload.username
        })),
    )
        .into_response())
}

async fn logout(State(ctx): State<AppContext>, headers: HeaderMap) -> Result<Response, StatusCode> {
    if let Some(token) = get_session_token(&headers) {
        ctx.db
            .execute_raw(Statement::from_sql_and_values(
                DbBackend::Postgres,
                "DELETE FROM admin_sessions WHERE token=$1",
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

    Ok((resp_headers, Json(serde_json::json!({ "ok": true }))).into_response())
}

#[derive(Deserialize)]
struct ChangePasswordRequest {
    current_password: String,
    new_password: String,
}

async fn change_password(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
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
    let session = get_session_token(&headers).ok_or(StatusCode::UNAUTHORIZED)?;
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
        "DELETE FROM admin_sessions WHERE username=$1 AND token <> $2",
        vec![username.into(), session.into()],
    ))
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tx.commit()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn list_accounts(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
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

        accounts.push(serde_json::json!({
            "id": id,
            "cursor": cursor,
            "used_bytes": used_bytes,
            "quota_bytes": quota_bytes,
            "revision_count": revision_count,
            "max_revisions": max_revisions,
            "needs_key": needs_key,
            "devices": devices
        }));
    }

    Ok(Json(serde_json::json!(accounts)))
}

async fn create_account(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let id = Uuid::new_v4().to_string();
    ctx.db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "INSERT INTO accounts(id) VALUES($1::uuid)",
            vec![id.clone().into()],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(serde_json::json!({ "id": id })))
}

async fn delete_account(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(account_id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
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
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

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

    if let Some(store) = ctx.shared_store.get::<crate::api::BlobStore>() {
        store.remove_account(&account_id).await.map_err(|error| {
            tracing::error!(%error, "could not remove deleted account blobs");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    }

    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn add_device(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(account_id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let _ = authenticate_admin(&ctx.db, &headers).await?;

    let account = Uuid::parse_str(&account_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let token = new_secret();
    let device_id = Uuid::new_v4().to_string();
    let token_hash = hex::encode(Sha256::digest(token.as_bytes()));

    ctx.db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "INSERT INTO devices(id, account_id, token_hash) VALUES($1::uuid, $2::uuid, $3)",
            vec![
                device_id.clone().into(),
                account.to_string().into(),
                token_hash.into(),
            ],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(serde_json::json!({
        "id": device_id,
        "token": token
    })))
}

async fn revoke_device(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
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
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

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

    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn unrevoke_device(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
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
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

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

    Ok(Json(serde_json::json!({ "ok": true })))
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
