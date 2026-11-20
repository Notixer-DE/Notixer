use crate::openapi::DeviceToken;
use crate::{
    admin::authenticate_admin,
    api::{ApiError, new_secret, valid_id},
};
use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
};
use loco_rs::app::AppContext;
use sea_orm::{ConnectionTrait, DbBackend, Statement, TransactionTrait, Value};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use sha2::{Digest, Sha256};
use utoipa::ToSchema;
use uuid::Uuid;

const TTL_SECONDS: i32 = 300;

fn statement(sql: &str, values: Vec<Value>) -> Statement {
    Statement::from_sql_and_values(DbBackend::Postgres, sql, values)
}

fn hash(secret: &str) -> String {
    hex::encode(Sha256::digest(secret.as_bytes()))
}

type SecretResponse<T> = ([(header::HeaderName, &'static str); 1], Json<T>);

#[derive(Serialize, ToSchema)]
pub(crate) struct PairingInvitation {
    #[schema(pattern = "^[a-f0-9]{64}$")]
    code: String,
    account: Uuid,
    needs_key: bool,
    expires_in: i32,
}

#[utoipa::path(
    post, path = "/admin/api/accounts/{id}/pairing", tag = "Pairing",
    summary = "Issue a five-minute, single-use QR pairing code",
    operation_id = "createPairingCode", security(("admin_session" = [])),
    params(("id" = Uuid, Path, description = "Account UUID")),
    request_body(content = Object, description = "Send an empty JSON object"),
    responses((status = 200, body = PairingInvitation), (status = 401, body = crate::openapi::ErrorBody), (status = 403, description = "Cross-origin admin request rejected"), (status = 404, body = crate::openapi::ErrorBody))
)]
pub(crate) async fn create(
    State(ctx): State<AppContext>,
    Path(account): Path<Uuid>,
    headers: HeaderMap,
    Json(_): Json<serde_json::Map<String, JsonValue>>,
) -> Result<SecretResponse<PairingInvitation>, ApiError> {
    authenticate_admin(&ctx.db, &headers)
        .await
        .map_err(ApiError)?;
    let code = new_secret();
    let row = ctx.db.query_one_raw(statement(
        "WITH account AS (
            SELECT id, key_check FROM accounts WHERE id = $1::uuid FOR UPDATE
        ), invite AS (
            INSERT INTO pairing_codes (account_id, code_hash, expires_at)
            SELECT id, $2, now() + ($3::integer * interval '1 second') FROM account
            ON CONFLICT (account_id) DO UPDATE
                SET code_hash = excluded.code_hash, expires_at = excluded.expires_at
            RETURNING account_id
        ) SELECT key_check IS NOT NULL AS needs_key FROM account JOIN invite ON account.id = invite.account_id",
        vec![account.to_string().into(), hash(&code).into(), TTL_SECONDS.into()],
    )).await?.ok_or(ApiError(StatusCode::NOT_FOUND))?;
    let needs_key: bool = row.try_get("", "needs_key")?;
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(PairingInvitation {
            code,
            account,
            needs_key,
            expires_in: TTL_SECONDS,
        }),
    ))
}

#[derive(Deserialize, ToSchema)]
pub(crate) struct Redemption {
    account: Uuid,
    #[schema(pattern = "^[a-f0-9]{64}$")]
    code: String,
    #[schema(pattern = "^[a-f0-9]{64}$")]
    key_check: String,
}

#[utoipa::path(
    post, path = "/api/v1/pairing/redeem", tag = "Pairing",
    summary = "Redeem a QR pairing code for a device token",
    request_body = Redemption,
    responses((status = 200, body = DeviceToken), (status = 400, body = crate::openapi::ErrorBody), (status = 401, description = "Pairing code expired, used or invalid", body = crate::openapi::ErrorBody), (status = 409, description = "Recovery key check does not match", body = crate::openapi::ErrorBody))
)]
pub(crate) async fn redeem(
    State(ctx): State<AppContext>,
    Json(body): Json<Redemption>,
) -> Result<SecretResponse<DeviceToken>, ApiError> {
    if !valid_id(&body.code) || !valid_id(&body.key_check) {
        return Err(ApiError(StatusCode::BAD_REQUEST));
    }
    let account = body.account.to_string();
    let code_hash = hash(&body.code);
    let tx = ctx.db.begin().await?;
    // Lock the account first, like sync writers. Check the invitation before
    // disclosing a mismatch, and consume it in the same transaction as enrolment.
    let row = tx
        .query_one_raw(statement(
            "SELECT key_check FROM accounts AS a
         WHERE a.id = $1::uuid AND EXISTS (
             SELECT 1 FROM pairing_codes WHERE account_id = a.id AND code_hash = $2
               AND expires_at > now()
         ) FOR UPDATE",
            vec![account.clone().into(), code_hash.clone().into()],
        ))
        .await?
        .ok_or(ApiError(StatusCode::UNAUTHORIZED))?;
    let key_check: Option<String> = row.try_get("", "key_check")?;
    if key_check.is_some_and(|check| check != body.key_check) {
        return Err(ApiError(StatusCode::CONFLICT));
    }
    let consumed = tx
        .execute_raw(statement(
            "DELETE FROM pairing_codes WHERE account_id = $1::uuid AND code_hash = $2
           AND expires_at > clock_timestamp()",
            vec![account.clone().into(), code_hash.into()],
        ))
        .await?;
    if consumed.rows_affected() != 1 {
        return Err(ApiError(StatusCode::UNAUTHORIZED));
    }
    let token = new_secret();
    let device = Uuid::new_v4();
    tx.execute_raw(statement(
        "INSERT INTO devices (id, account_id, token_hash) VALUES ($1::uuid, $2::uuid, $3)",
        vec![
            device.to_string().into(),
            account.into(),
            hash(&token).into(),
        ],
    ))
    .await?;
    tx.commit().await?;
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(DeviceToken { id: device, token }),
    ))
}
