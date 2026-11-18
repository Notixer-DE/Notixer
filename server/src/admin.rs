use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{delete, get, post},
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use rand::RngCore;
use sea_orm::{ConnectionTrait, DatabaseConnection, DbBackend, Statement, TransactionTrait};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use uuid::Uuid;

const HTML_CONTENT: &str = include_str!("assets/admin.html");
const VUE_JS: &str = include_str!("assets/vue.global.prod.js");

pub fn hash_password(password: &str) -> Result<String, String> {
    let argon2 = Argon2::default();
    let salt = SaltString::generate(&mut OsRng);
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
        .add("/", get(index))
        .add("/assets/vue.js", get(vue_asset))
        .add("/api/me", get(me))
        .add("/api/login", post(login))
        .add("/api/logout", post(logout))
        .add("/api/change-password", post(change_password))
        .add("/api/accounts", get(list_accounts).post(create_account))
        .add("/api/accounts/{id}", delete(delete_account))
        .add("/api/accounts/{id}/devices", post(add_device))
        .add("/api/devices/{id}/revoke", post(revoke_device))
        .add("/api/devices/{id}/unrevoke", post(unrevoke_device))
}

async fn index() -> impl IntoResponse {
    Html(HTML_CONTENT)
}

async fn vue_asset() -> impl IntoResponse {
    (
        [(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/javascript; charset=utf-8"),
        )],
        VUE_JS,
    )
}

fn get_session_token(headers: &HeaderMap) -> Option<String> {
    let cookie_header = headers.get(header::COOKIE)?.to_str().ok()?;
    for cookie in cookie_header.split(';') {
        let mut parts = cookie.trim().splitn(2, '=');
        if let (Some(name), Some(val)) = (parts.next(), parts.next()) {
            if name == "noter_admin_session" && !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

async fn authenticate_admin(
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
        Err(_) => Ok(Json(serde_json::json!({
            "authenticated": false
        }))),
    }
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

async fn login(
    State(ctx): State<AppContext>,
    Json(payload): Json<LoginRequest>,
) -> Result<Response, StatusCode> {
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

    if !verify_password(&payload.password, &hash) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let mut random = [0u8; 32];
    rand::rng().fill_bytes(&mut random);
    let session_token = hex::encode(random);

    ctx.db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "INSERT INTO admin_sessions(token, username, expires_at) VALUES($1, $2, now() + interval '7 days')",
            vec![session_token.clone().into(), payload.username.clone().into()],
        ))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let cookie_val = format!(
        "noter_admin_session={session_token}; Path=/admin; HttpOnly; SameSite=Lax; Max-Age={}",
        7 * 24 * 3600
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

async fn logout(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    if let Some(token) = get_session_token(&headers) {
        let _ = ctx
            .db
            .execute_raw(Statement::from_sql_and_values(
                DbBackend::Postgres,
                "DELETE FROM admin_sessions WHERE token=$1",
                vec![token.into()],
            ))
            .await;
    }

    let mut resp_headers = HeaderMap::new();
    resp_headers.insert(
        header::SET_COOKIE,
        HeaderValue::from_static(
            "noter_admin_session=; Path=/admin; HttpOnly; SameSite=Lax; Max-Age=0",
        ),
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

    if payload.new_password.trim().len() < 4 {
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

    if !verify_password(&payload.current_password, &current_hash) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let new_hash =
        hash_password(&payload.new_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    ctx.db
        .execute_raw(Statement::from_sql_and_values(
            DbBackend::Postgres,
            "UPDATE admin_users SET password_hash=$1 WHERE username=$2",
            vec![new_hash.into(), username.into()],
        ))
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
                a.key_check,
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
        let id: String = row.try_get("", "id").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let cursor: i64 = row.try_get("", "cursor").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let used_bytes: i64 = row.try_get("", "used_bytes").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let quota_bytes: i64 = row.try_get("", "quota_bytes").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let revision_count: i64 = row.try_get("", "revision_count").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let max_revisions: i64 = row.try_get("", "max_revisions").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let key_check: Option<String> = row.try_get("", "key_check").ok();
        let devices: serde_json::Value = row.try_get("", "devices").unwrap_or_else(|_| serde_json::json!([]));

        accounts.push(serde_json::json!({
            "id": id,
            "cursor": cursor,
            "used_bytes": used_bytes,
            "quota_bytes": quota_bytes,
            "revision_count": revision_count,
            "max_revisions": max_revisions,
            "key_check": key_check,
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
    let _ = Uuid::parse_str(&account_id).map_err(|_| StatusCode::BAD_REQUEST)?;

    let tx = ctx.db.begin().await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

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

    tx.commit().await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    if let Ok(blob_dir) = std::env::var("BLOB_DIR") {
        let path = std::path::Path::new(&blob_dir).join(&account_id);
        let _ = tokio::fs::remove_dir_all(path).await;
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
    let mut random = [0u8; 32];
    rand::rng().fill_bytes(&mut random);
    let token = hex::encode(random);
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
    fn default_admin_password_hashes_and_verifies() {
        let hash = hash_password("admin").expect("hashing failed");
        assert!(verify_password("admin", &hash));
        assert!(!verify_password("wrong", &hash));
    }
}
