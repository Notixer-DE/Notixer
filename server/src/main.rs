mod admin;
mod admin_assets;
mod api;
mod app;
mod live;
mod migration;
mod openapi;
mod pairing;

#[tokio::main]
async fn main() -> loco_rs::Result<()> {
    // Administrative credentials are generated locally and printed once, never
    // accepted in command arguments or exposed by a public registration route.
    if std::env::args().nth(1).as_deref() == Some("admin") {
        return api::admin().await;
    }
    if std::env::args().nth(1).as_deref() == Some("openapi") {
        return openapi::print();
    }
    loco_rs::cli::main::<app::App, migration::Migrator>().await
}
