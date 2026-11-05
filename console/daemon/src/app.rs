//! The routes. Each page route answers HTML, or JSON for `Accept: application/json`; the
//! pages are rendered in `pages`. This first part only reads: no route changes anything.
//! Every page needs someone signed in (`auth`, or the development identity); the assets and
//! the sign-in routes do not.

use crate::auth::{self, Oidc, Refused};
use crate::{FONTS, pages};
use axum::Router;
use axum::extract::{Extension, Path, Query, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use golconda_core::diff::{Change, against_git};
use golconda_core::document::parse_path;
use golconda_core::eval::Iets;
use golconda_core::system::{Explanation, System};
use serde_json::Value;
use std::collections::HashMap;
use std::env::consts;
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

/// Who is signed in.
#[derive(Debug, Clone)]
pub struct Identity {
    /// the OIDC subject (`dev:NAME` for the development identity)
    pub id: String,
    pub name: String,
    pub level: Level,
}

/// How people sign in.
pub enum Signin {
    /// everyone is this one identity (`--dev-identity`, loopback only)
    Dev(Identity),
    Oidc(Box<Oidc>),
}

pub struct App {
    /// name -> the system's document
    pub systems: Vec<(String, PathBuf)>,
    pub signin: Signin,
    /// the whole daemon is read-only (`--read-only`)
    pub read_only: bool,
    pub iets: Iets,
    /// the Nix system to evaluate for
    pub platform: String,
}

impl App {
    pub fn new(systems: Vec<(String, PathBuf)>, signin: Signin, read_only: bool) -> Self {
        App {
            systems,
            signin,
            read_only,
            iets: Iets::from_env(),
            platform: format!("{}-linux", consts::ARCH),
        }
    }

    fn document(&self, name: &str) -> Option<&PathBuf> {
        self.systems.iter().find(|(n, _)| n == name).map(|(_, p)| p)
    }
}

type Shared = Arc<App>;

pub fn router(app: App) -> Router {
    let app = Arc::new(app);
    let pages = Router::new()
        .route("/", get(index))
        .route("/systems/{name}", get(system_root))
        .route("/systems/{name}/config", get(config))
        .route("/systems/{name}/config/{*module}", get(module))
        .route("/systems/{name}/changes", get(changes))
        .route("/auth/me", get(me))
        .layer(middleware::from_fn_with_state(app.clone(), signed_in));
    Router::new()
        .merge(pages)
        .route("/auth/login", get(login))
        .route("/auth/callback", get(callback))
        .route("/auth/logout", post(logout))
        .route("/assets/style.css", get(style))
        .route("/assets/fonts/{file}", get(font))
        .layer(middleware::from_fn_with_state(app.clone(), headers))
        .with_state(app)
}

/// The Host a browser sent is ours: the public address's with OIDC, a loopback name with the
/// development identity. A page elsewhere whose name resolves to this daemon (DNS
/// rebinding) sends its own. A request without Host is no browser's.
fn our_host(app: &App, req: &Request) -> bool {
    let Some(host) = req.headers().get(header::HOST) else {
        return true;
    };
    let host = host.to_str().unwrap_or("");
    let name = match host.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => host.split(':').next().unwrap_or(""),
    };
    match &app.signin {
        Signin::Dev(_) => auth::is_loopback(name),
        Signin::Oidc(o) => name == o.public_host(),
    }
}

/// On every answer: nothing from elsewhere, no framing, no sniffing.
async fn headers(State(app): State<Shared>, req: Request, next: Next) -> Response {
    if !our_host(&app, &req) {
        return (
            StatusCode::MISDIRECTED_REQUEST,
            "this daemon answers on its own name only\n",
        )
            .into_response();
    }
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

fn session_cookie(h: &HeaderMap) -> Option<&str> {
    h.get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .find_map(|c| c.trim().strip_prefix(auth::COOKIE)?.strip_prefix('='))
}

/// Who is signed in, for the pages (an `Identity` extension). Nobody: a browser goes to sign
/// in and comes back, JSON gets 401.
async fn signed_in(State(app): State<Shared>, mut req: Request, next: Next) -> Response {
    let who = match &app.signin {
        Signin::Dev(who) => Some(who.clone()),
        Signin::Oidc(o) => session_cookie(req.headers()).and_then(|id| o.session(id)),
    };
    let Some(who) = who else {
        // /auth/me is JSON whatever the request accepts
        if wants_json(req.headers()) || req.uri().path() == "/auth/me" {
            return problem(true, StatusCode::UNAUTHORIZED, "sign in first");
        }
        let here = req.uri().path_and_query().map_or("/", |p| p.as_str());
        return Redirect::to(&format!("/auth/login?next={}", auth::encode(here))).into_response();
    };
    req.extensions_mut().insert(who);
    next.run(req).await
}

async fn login(State(app): State<Shared>, Query(q): Query<HashMap<String, String>>) -> Redirect {
    let next = auth::safe_next(q.get("next").map_or("/", String::as_str));
    match &app.signin {
        Signin::Dev(_) => Redirect::to(&next),
        Signin::Oidc(o) => Redirect::to(&o.begin(&next)),
    }
}

async fn callback(State(app): State<Shared>, Query(q): Query<HashMap<String, String>>) -> Response {
    let Signin::Oidc(_) = &app.signin else {
        return Redirect::to("/").into_response();
    };
    if let Some(e) = q.get("error") {
        let why = q.get("error_description").unwrap_or(e);
        return problem(
            false,
            StatusCode::BAD_REQUEST,
            &format!("the provider refused: {why}"),
        );
    }
    let (code, state) = (
        q.get("code").cloned().unwrap_or_default(),
        q.get("state").cloned(),
    );
    let Some(state) = state else {
        return problem(false, StatusCode::BAD_REQUEST, "no state");
    };
    let a = app.clone();
    let done = tokio::task::spawn_blocking(move || match &a.signin {
        Signin::Oidc(o) => o.finish(&code, &state),
        Signin::Dev(_) => unreachable!("checked above"),
    })
    .await
    .expect("sign-in thread");
    let secure = matches!(&app.signin, Signin::Oidc(o) if o.secure());
    match done {
        Ok((id, next)) => {
            let cookie = format!(
                "{}={id}; Path=/; HttpOnly; SameSite=Lax; Max-Age=43200{}",
                auth::COOKIE,
                if secure { "; Secure" } else { "" }
            );
            ([(header::SET_COOKIE, cookie)], Redirect::to(&next)).into_response()
        }
        Err(Refused::Bad(m)) => problem(false, StatusCode::BAD_REQUEST, &m),
        Err(Refused::NotAllowed(m)) => problem(false, StatusCode::FORBIDDEN, &m),
    }
}

/// End the session. A POST: a link elsewhere cannot sign anyone out, and the Lax cookie does
/// not come along with another site's form.
async fn logout(State(app): State<Shared>, h: HeaderMap) -> Response {
    if let (Signin::Oidc(o), Some(id)) = (&app.signin, session_cookie(&h)) {
        o.end(id);
    }
    let cookie = format!(
        "{}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
        auth::COOKIE
    );
    ([(header::SET_COOKIE, cookie)], Redirect::to("/")).into_response()
}

async fn me(Extension(who): Extension<Identity>) -> axum::Json<Value> {
    axum::Json(serde_json::json!({ "id": who.id, "name": who.name, "level": who.level.name() }))
}

fn wants_json(h: &HeaderMap) -> bool {
    h.get(header::ACCEPT)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|a| a.contains("application/json"))
}

/// An answer that is not the page: a status and a sentence, as HTML or JSON.
fn problem(json: bool, status: StatusCode, message: &str) -> Response {
    if json {
        (status, axum::Json(serde_json::json!({ "error": message }))).into_response()
    } else {
        (status, pages::problem(status, message)).into_response()
    }
}

/// Evaluate a system off the async threads (an evaluation is a process, 0.1 to 0.4 s).
async fn load(app: &Shared, name: &str, json: bool) -> Result<System, Box<Response>> {
    let Some(doc) = app.document(name).cloned() else {
        let missing = format!("no system {name}");
        return Err(Box::new(problem(json, StatusCode::NOT_FOUND, &missing)));
    };
    let a = app.clone();
    let loaded = tokio::task::spawn_blocking(move || System::load(&a.iets, &doc, &a.platform))
        .await
        .expect("evaluation thread");
    loaded.map_err(|e| {
        Box::new(problem(
            json,
            StatusCode::INTERNAL_SERVER_ERROR,
            &e.to_string(),
        ))
    })
}

async fn index(State(app): State<Shared>, Extension(who): Extension<Identity>) -> Response {
    match app.systems.as_slice() {
        [(name, _)] => Redirect::to(&format!("/systems/{name}/config")).into_response(),
        systems => pages::index(&app, &who, systems).into_response(),
    }
}

async fn system_root(Path(name): Path<String>) -> Redirect {
    Redirect::to(&format!("/systems/{name}/config"))
}

async fn config(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Path(name): Path<String>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    let sys = match load(&app, &name, json).await {
        Ok(s) => s,
        Err(r) => return *r,
    };
    if json {
        return axum::Json(sys.config.clone()).into_response();
    }
    pages::config(&app, &who, &name, &sys).into_response()
}

async fn module(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
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
        return problem(json, StatusCode::NOT_FOUND, &format!("no module {module}"));
    }
    let empty = serde_json::Map::new();
    let props = sys.schema["properties"][&module]["properties"]
        .as_object()
        .unwrap_or(&empty);
    let mut options = Vec::new();
    for o in props.keys() {
        match sys.explain(&module, &[o]) {
            Ok(e) => options.push(e),
            Err(e) => return problem(json, StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
        }
    }
    let selected = match option.as_deref().map(parse_path) {
        None => None,
        Some(Err(e)) => return problem(json, StatusCode::NOT_FOUND, &e.to_string()),
        Some(Ok(p)) => {
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            match sys.explain(&module, &p) {
                Ok(e) => Some(e),
                Err(e) => return problem(json, StatusCode::NOT_FOUND, &e.to_string()),
            }
        }
    };
    if json {
        let doc = sys.module_docs.get(&module).cloned().unwrap_or(Value::Null);
        return axum::Json(serde_json::json!({
            "module": module,
            "doc": doc,
            "included": sys.config.get(&module).is_some(),
            "options": options.iter().map(Explanation::to_json).collect::<Vec<_>>(),
        }))
        .into_response();
    }
    pages::module(
        &app,
        &who,
        &name,
        &sys,
        &module,
        &options,
        selected.as_ref(),
    )
    .into_response()
}

async fn changes(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Path(name): Path<String>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    let Some(doc) = app.document(&name).cloned() else {
        return problem(json, StatusCode::NOT_FOUND, &format!("no system {name}"));
    };
    let a = app.clone();
    let both = tokio::task::spawn_blocking(move || against_git(&a.iets, &doc, "HEAD", &a.platform))
        .await
        .expect("evaluation thread");
    let (sys, changes) = match both {
        Ok(x) => x,
        Err(e) => return problem(json, StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
    };
    if json {
        return axum::Json(Value::Array(changes.iter().map(Change::to_json).collect()))
            .into_response();
    }
    pages::changes(&app, &who, &name, &sys, &changes).into_response()
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
    match FONTS.iter().find(|(n, _)| *n == file) {
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
