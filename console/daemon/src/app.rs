//! The routes. Each page route answers HTML, or JSON for `Accept: application/json`; the
//! pages are rendered in `pages`. This first part only reads: no route changes anything.

use crate::pages;
use axum::Router;
use axum::extract::{Path, Query, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::get;
use golconda_core::diff::{Change, against_git};
use golconda_core::document::parse_path;
use golconda_core::eval::Iets;
use golconda_core::system::System;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    ReadOnly,
    Operator,
}

impl Level {
    pub fn name(self) -> &'static str {
        match self {
            Level::ReadOnly => "read-only",
            Level::Operator => "operator",
        }
    }
}

/// Who is signed in. OIDC is the next part; until then the one identity `--dev-identity`
/// gives (main.rs).
#[derive(Debug, Clone)]
pub struct Identity {
    pub name: String,
    pub level: Level,
}

pub struct App {
    /// name -> the system's document
    pub systems: Vec<(String, PathBuf)>,
    pub identity: Identity,
    /// the whole daemon is read-only (`--read-only`)
    pub read_only: bool,
    pub iets: Iets,
    /// the Nix system to evaluate for
    pub platform: String,
}

impl App {
    pub fn new(systems: Vec<(String, PathBuf)>, identity: Identity, read_only: bool) -> Self {
        App {
            systems,
            identity,
            read_only,
            iets: Iets::from_env(),
            platform: format!("{}-linux", std::env::consts::ARCH),
        }
    }

    fn document(&self, name: &str) -> Option<&PathBuf> {
        self.systems.iter().find(|(n, _)| n == name).map(|(_, p)| p)
    }
}

type Shared = Arc<App>;

pub fn router(app: App) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/systems/{name}", get(system_root))
        .route("/systems/{name}/config", get(config))
        .route("/systems/{name}/config/{*module}", get(module))
        .route("/systems/{name}/changes", get(changes))
        .route("/assets/style.css", get(style))
        .route("/assets/fonts/{file}", get(font))
        .layer(middleware::from_fn(headers))
        .with_state(Arc::new(app))
}

/// On every answer: nothing from elsewhere, no framing, no sniffing.
async fn headers(req: Request, next: Next) -> Response {
    let mut res = next.run(req).await;
    let h = res.headers_mut();
    h.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; \
             font-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        ),
    );
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    h.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("same-origin"),
    );
    res
}

fn wants_json(h: &HeaderMap) -> bool {
    h.get(header::ACCEPT)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|a| a.contains("application/json"))
}

/// An answer that is not the page: a status and a sentence, as HTML or JSON.
fn problem(json: bool, status: StatusCode, message: String) -> Response {
    if json {
        (status, axum::Json(serde_json::json!({ "error": message }))).into_response()
    } else {
        (status, pages::problem(status, &message)).into_response()
    }
}

/// Evaluate a system off the async threads (an evaluation is a process, 0.1 to 0.4 s).
async fn load(app: &Shared, name: &str, json: bool) -> Result<System, Box<Response>> {
    let Some(doc) = app.document(name).cloned() else {
        let missing = format!("no system {name}");
        return Err(Box::new(problem(json, StatusCode::NOT_FOUND, missing)));
    };
    let a = app.clone();
    let loaded = tokio::task::spawn_blocking(move || System::load(&a.iets, &doc, &a.platform))
        .await
        .expect("evaluation thread");
    loaded.map_err(|e| {
        Box::new(problem(
            json,
            StatusCode::INTERNAL_SERVER_ERROR,
            e.to_string(),
        ))
    })
}

async fn index(State(app): State<Shared>) -> Response {
    match app.systems.as_slice() {
        [(name, _)] => Redirect::to(&format!("/systems/{name}/config")).into_response(),
        systems => pages::index(&app, systems).into_response(),
    }
}

async fn system_root(Path(name): Path<String>) -> Redirect {
    Redirect::to(&format!("/systems/{name}/config"))
}

async fn config(State(app): State<Shared>, Path(name): Path<String>, h: HeaderMap) -> Response {
    let json = wants_json(&h);
    let sys = match load(&app, &name, json).await {
        Ok(s) => s,
        Err(r) => return *r,
    };
    if json {
        return axum::Json(sys.config.clone()).into_response();
    }
    pages::config(&app, &name, &sys).into_response()
}

async fn module(
    State(app): State<Shared>,
    Path((name, module)): Path<(String, String)>,
    Query(q): Query<HashMap<String, String>>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    let option = q.get("option").cloned();
    let module = format!("/{}", module.trim_end_matches('/'));
    let sys = match load(&app, &name, json).await {
        Ok(s) => s,
        Err(r) => return *r,
    };
    // a module with no options of its own (/vars) has no properties
    if !sys.schema["properties"][&module].is_object() {
        return problem(json, StatusCode::NOT_FOUND, format!("no module {module}"));
    }
    let empty = serde_json::Map::new();
    let props = sys.schema["properties"][&module]["properties"]
        .as_object()
        .unwrap_or(&empty);
    let mut options = Vec::new();
    for o in props.keys() {
        match sys.explain(&module, &[o]) {
            Ok(e) => options.push(e),
            Err(e) => return problem(json, StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
        }
    }
    let selected = match option.as_deref().map(parse_path) {
        None => None,
        Some(Err(e)) => return problem(json, StatusCode::NOT_FOUND, e.to_string()),
        Some(Ok(p)) => {
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            match sys.explain(&module, &p) {
                Ok(e) => Some(e),
                Err(e) => return problem(json, StatusCode::NOT_FOUND, e.to_string()),
            }
        }
    };
    if json {
        let doc = sys.module_docs.get(&module).cloned().unwrap_or(Value::Null);
        return axum::Json(serde_json::json!({
            "module": module,
            "doc": doc,
            "included": sys.config.get(&module).is_some(),
            "options": options.iter().map(|e| e.to_json()).collect::<Vec<_>>(),
        }))
        .into_response();
    }
    pages::module(&app, &name, &sys, &module, &options, selected.as_ref()).into_response()
}

async fn changes(State(app): State<Shared>, Path(name): Path<String>, h: HeaderMap) -> Response {
    let json = wants_json(&h);
    let Some(doc) = app.document(&name).cloned() else {
        return problem(json, StatusCode::NOT_FOUND, format!("no system {name}"));
    };
    let a = app.clone();
    let both = tokio::task::spawn_blocking(move || against_git(&a.iets, &doc, "HEAD", &a.platform))
        .await
        .expect("evaluation thread");
    let (sys, changes) = match both {
        Ok(x) => x,
        Err(e) => return problem(json, StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
    };
    if json {
        return axum::Json(Value::Array(changes.iter().map(Change::to_json).collect()))
            .into_response();
    }
    pages::changes(&app, &name, &sys, &changes).into_response()
}

async fn style() -> Response {
    (
        [
            (header::CONTENT_TYPE, "text/css; charset=utf-8"),
            (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
        ],
        include_str!("style.css"),
    )
        .into_response()
}

async fn font(Path(file): Path<String>) -> Response {
    match crate::FONTS.iter().find(|(n, _)| *n == file) {
        Some((_, bytes)) => (
            [
                (header::CONTENT_TYPE, "font/woff2"),
                (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
            ],
            *bytes,
        )
            .into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
