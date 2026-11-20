use axum::{
    http::header,
    response::{Html, IntoResponse},
};

const INDEX: &str = include_str!("../admin-ui/dist/index.html");
const SCRIPT: &str = include_str!("../admin-ui/dist/assets/admin.js");
const STYLE: &str = include_str!("../admin-ui/dist/assets/admin.css");

pub(crate) async fn index() -> impl IntoResponse {
    (
        [
            (header::CACHE_CONTROL, "no-store"),
            (
                header::CONTENT_SECURITY_POLICY,
                "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src data: 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
            ),
            (header::REFERRER_POLICY, "no-referrer"),
        ],
        Html(INDEX),
    )
}

pub(crate) async fn script() -> impl IntoResponse {
    static_asset("application/javascript; charset=utf-8", SCRIPT)
}

pub(crate) async fn stylesheet() -> impl IntoResponse {
    static_asset("text/css; charset=utf-8", STYLE)
}

fn static_asset(media_type: &'static str, content: &'static str) -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, media_type),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        content,
    )
}
