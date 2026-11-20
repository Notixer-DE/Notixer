use std::{io::Write, sync::OnceLock};

use axum::{Json, routing::MethodRouter};
use loco_rs::{app::AppContext, controller::Routes};
use utoipa::{
    OpenApi, ToSchema,
    openapi::security::{ApiKey, ApiKeyValue, Http, HttpAuthScheme, SecurityScheme},
};
use utoipa_axum::router::UtoipaMethodRouter;

#[derive(OpenApi)]
#[openapi(info(
    title = "Notixer Sync Server",
    description = "Encrypted library sync, device pairing, Live Canvas, and the administration API. The Live Canvas WebSocket operation describes the HTTP upgrade and its authentication."
))]
struct Metadata;

pub(crate) struct DocumentedRoutes {
    pub routes: Routes,
    spec: utoipa::openapi::OpenApi,
}

impl DocumentedRoutes {
    pub fn new() -> Self {
        Self {
            routes: Routes::new(),
            spec: Metadata::openapi(),
        }
    }

    // Use the path and method produced by the same annotation for both Loco
    // and the OpenAPI document. Combine methods sharing a path in one routes! call.
    pub fn add(mut self, (schemas, paths, handlers): UtoipaMethodRouter<AppContext>) -> Self {
        let mut paths = paths.paths.into_iter();
        let (path, item) = paths.next().expect("a documented route must have a path");
        assert!(
            paths.next().is_none(),
            "group only methods sharing one path"
        );
        self.routes = self.routes.add(&path, handlers);
        assert!(
            self.spec.paths.paths.insert(path, item).is_none(),
            "duplicate documented path"
        );
        self.spec
            .components
            .get_or_insert_with(Default::default)
            .schemas
            .extend(schemas);
        self
    }

    pub fn asset(mut self, path: &str, handler: MethodRouter<AppContext>) -> Self {
        self.routes = self.routes.add(path, handler);
        self
    }
}

fn document() -> &'static utoipa::openapi::OpenApi {
    static DOCUMENT: OnceLock<utoipa::openapi::OpenApi> = OnceLock::new();
    DOCUMENT.get_or_init(|| {
        let mut doc = crate::api::routes().spec;
        doc.merge(crate::admin::routes().spec);
        let components = doc.components.get_or_insert_with(Default::default);
        components.add_security_scheme(
            "device_token",
            SecurityScheme::Http(Http::new(HttpAuthScheme::Bearer)),
        );
        components.add_security_scheme(
            "admin_session",
            SecurityScheme::ApiKey(ApiKey::Cookie(ApiKeyValue::new("noter_admin_session"))),
        );
        doc
    })
}

#[utoipa::path(
    get,
    path = "/api/v1/openapi.json",
    tag = "Documentation",
    responses((status = 200, description = "OpenAPI contract for this server build", body = Object))
)]
pub(crate) async fn json() -> Json<&'static utoipa::openapi::OpenApi> {
    Json(document())
}

pub(crate) fn print() -> loco_rs::Result<()> {
    let mut out = std::io::stdout().lock();
    serde_json::to_writer_pretty(&mut out, document())
        .map_err(|error| loco_rs::Error::Message(error.to_string()))?;
    writeln!(out).map_err(|error| loco_rs::Error::Message(error.to_string()))?;
    Ok(())
}

#[derive(serde::Serialize, ToSchema)]
pub(crate) struct DeviceToken {
    pub id: uuid::Uuid,
    #[schema(pattern = "^[a-f0-9]{64}$")]
    pub token: String,
}

#[derive(serde::Serialize, ToSchema)]
pub(crate) struct ApiStatus {
    pub ok: bool,
}

#[derive(serde::Serialize, ToSchema)]
pub(crate) struct ErrorBody {
    pub error: u16,
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use loco_rs::controller::AppRoutes;

    #[test]
    fn openapi_covers_all_loco_api_routes() {
        let routes = AppRoutes::empty()
            .add_route(crate::api::routes().routes)
            .add_route(crate::admin::routes().routes);
        let runtime: BTreeSet<_> = routes
            .collect()
            .into_iter()
            .filter(|route| route.uri.starts_with("/api/") || route.uri.starts_with("/admin/api/"))
            .flat_map(|route| {
                route
                    .actions
                    .into_iter()
                    .map(move |method| (route.uri.clone(), method.as_str().to_ascii_lowercase()))
            })
            .collect();
        let doc = serde_json::to_value(super::document()).unwrap();
        let mut described = BTreeSet::new();
        let mut ids = BTreeSet::new();
        for (path, methods) in doc["paths"].as_object().unwrap() {
            for (verb, operation) in methods.as_object().unwrap() {
                assert!(ids.insert(operation["operationId"].as_str().unwrap()));
                described.insert((path.clone(), verb.clone()));
            }
        }
        assert_eq!(described, runtime);
        assert_eq!(
            doc["components"]["securitySchemes"]["admin_session"]["in"],
            "cookie"
        );
        assert_eq!(
            doc["components"]["securitySchemes"]["device_token"]["scheme"],
            "bearer"
        );
        assert_eq!(
            doc["paths"]["/api/v1/live/{id}"]["get"]["responses"]["101"]["description"],
            "WebSocket upgrade"
        );
    }
}
