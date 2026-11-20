use async_trait::async_trait;
use axum::{
    Router, extract::DefaultBodyLimit, http::StatusCode, middleware, response::IntoResponse,
};
use loco_rs::{
    Result,
    app::{AppContext, Hooks},
    bgworker::Queue,
    boot::{BootResult, StartMode, create_app},
    config::Config,
    controller::AppRoutes,
    environment::Environment,
    task::Tasks,
};
use std::path::Path;

pub struct App;

#[async_trait]
impl Hooks for App {
    fn app_name() -> &'static str {
        "noter-server"
    }

    async fn boot(mode: StartMode, env: &Environment, config: Config) -> Result<BootResult> {
        create_app::<Self, crate::migration::Migrator>(mode, env, config).await
    }

    fn routes(_ctx: &AppContext) -> AppRoutes {
        AppRoutes::empty()
            .add_route(crate::api::routes())
            .add_route(crate::admin::routes())
    }

    async fn after_context(ctx: AppContext) -> Result<AppContext> {
        let storage = crate::api::BlobStore::from_env().await?;
        ctx.shared_store.insert(storage);
        ctx.shared_store.insert(crate::live::LiveRooms::default());
        Ok(ctx)
    }

    async fn after_routes(router: Router, _ctx: &AppContext) -> Result<Router> {
        let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(64));
        Ok(router
            .layer(DefaultBodyLimit::max(crate::api::MAX_BLOCK))
            .layer(middleware::from_fn(
                move |request: axum::extract::Request, next: middleware::Next| {
                    let permits = permits.clone();
                    async move {
                        let Ok(_permit) = permits.try_acquire_owned() else {
                            return StatusCode::SERVICE_UNAVAILABLE.into_response();
                        };
                        next.run(request).await
                    }
                },
            )))
    }

    async fn connect_workers(_ctx: &AppContext, _queue: &Queue) -> Result<()> {
        Ok(())
    }
    fn register_tasks(_tasks: &mut Tasks) {}
    async fn truncate(_ctx: &AppContext) -> Result<()> {
        Err(loco_rs::Error::Message(
            "Automatic truncation is disabled".into(),
        ))
    }
    async fn seed(_ctx: &AppContext, _path: &Path) -> Result<()> {
        Ok(())
    }
}
