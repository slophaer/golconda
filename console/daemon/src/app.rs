//! The routes. Each page route answers HTML, or JSON for `Accept: application/json`; the
//! pages are rendered in `pages`. This first part only reads: no route changes anything.
//! Every page needs someone signed in (`auth`, or the development identity); the assets and
//! the sign-in routes do not.

use crate::auth::{self, Oidc, Refused};
use crate::write::Outcome;
use crate::{FONTS, events, jobs, locked, pages, write};
use axum::Router;
use axum::extract::{Extension, Path, Query, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use futures_util::stream;
use golconda_core::diff::{Change, against_git};
use golconda_core::document::parse_path;
use golconda_core::eval::Iets;
use golconda_core::system::{Explanation, System};
use serde_json::Value;
use std::collections::HashMap;
use std::convert::Infallible;
use std::env::consts;
use std::fmt;
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;
use std::thread;
use tokio::sync::broadcast;

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
/// The CSRF token the signed-in person's forms carry.
#[derive(Debug, Clone)]
pub struct Csrf(pub String);

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
    /// the journal and the audit log; none: this daemon only reads (no --state)
    pub writes: Option<write::Writes>,
    /// the jobs on machines; none without --state
    pub jobs: Option<jobs::Runner>,
    /// the live updates of each system (the optional script's stream)
    pub events: events::Hub,
    /// the CSRF token of the development identity's forms (with OIDC, each session has one)
    pub csrf: String,
    /// the whole daemon is read-only (`--read-only`)
    pub read_only: bool,
    pub iets: Iets,
    /// the Nix system to evaluate for
    pub platform: String,
}

impl App {
    /// # Panics
    ///
    /// When the system's random source fails: without it there is no CSRF token.
    pub fn new(systems: Vec<(String, PathBuf)>, signin: Signin, read_only: bool) -> Self {
        let mut b = [0u8; 32];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut b).expect("random");
        App {
            systems,
            signin,
            writes: None,
            jobs: None,
            events: events::Hub::default(),
            csrf: base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, b),
            read_only,
            iets: Iets::from_env(),
            platform: format!("{}-linux", consts::ARCH),
        }
    }

    /// This daemon writes, with the journal and audit log in `writes`.
    #[must_use]
    pub fn with_writes(mut self, writes: write::Writes) -> Self {
        self.writes = Some(writes);
        self
    }

    /// This daemon runs jobs on machines.
    #[must_use]
    pub fn with_jobs(mut self, jobs: jobs::Runner) -> Self {
        self.jobs = Some(jobs);
        self
    }

    pub fn document(&self, name: &str) -> Option<&PathBuf> {
        self.systems.iter().find(|(n, _)| n == name).map(|(_, p)| p)
    }
}

type Shared = Arc<App>;

pub fn router(app: App) -> Router {
    router_shared(Arc::new(app))
}

/// The routes, for an app something else holds too (the fetch timer).
pub fn router_shared(app: Arc<App>) -> Router {
    let pages = Router::new()
        .route("/", get(index))
        .route("/systems/{name}", get(system_root))
        .route("/systems/{name}/config", get(config))
        .route("/systems/{name}/config/{*module}", get(module))
        .route("/systems/{name}/changes", get(changes))
        .route("/systems/{name}/candidate", get(candidate))
        .route("/systems/{name}/ops", post(write_op))
        .route("/systems/{name}/commit", post(write_commit))
        .route("/systems/{name}/discard", post(write_discard))
        .route("/systems/{name}/lock", post(write_lock))
        .route("/systems/{name}/unlock", post(write_unlock))
        .route("/systems/{name}/lock/break", post(write_break_lock))
        .route("/systems/{name}/machines", get(machines))
        .route("/systems/{name}/events", get(live))
        .route("/systems/{name}/packages", get(packages))
        .route("/systems/{name}/sbom.json", get(sbom))
        .route("/systems/{name}/jobs", post(start_job))
        .route("/jobs", get(job_list))
        .route("/jobs/{id}", get(job_page))
        .route("/auth/me", get(me))
        .route("/audit", get(audit_log))
        .layer(middleware::from_fn_with_state(app.clone(), signed_in));
    Router::new()
        .merge(pages)
        .route("/auth/device", get(device))
        .route("/auth/login", get(login))
        .route("/auth/callback", get(callback))
        .route("/auth/logout", post(logout))
        .route("/assets/style.css", get(style))
        .route("/assets/live.js", get(script))
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

/// The token of `Authorization: Bearer`.
fn bearer(h: &HeaderMap) -> Option<String> {
    h.get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(|t| t.trim().to_string())
}

/// Where the CLI signs in (the device flow): the issuer, the CLI's client and the scopes.
async fn device(State(app): State<Shared>) -> Response {
    match &app.signin {
        Signin::Oidc(o) => match o.device_flow() {
            Some(v) => axum::Json(v).into_response(),
            None => problem(
                true,
                StatusCode::NOT_FOUND,
                "this daemon has no CLI sign-in (--oidc-cli-client-id, and a provider with the device flow)",
            ),
        },
        Signin::Dev(_) => problem(
            true,
            StatusCode::NOT_FOUND,
            "a development daemon needs no sign-in",
        ),
    }
}

/// Who is signed in, for the pages (an `Identity` extension). Nobody: a browser goes to sign
/// in and comes back, JSON gets 401. The CLI comes with a bearer token instead of a cookie;
/// it carries no CSRF token, as it sends no form.
async fn signed_in(State(app): State<Shared>, mut req: Request, next: Next) -> Response {
    let (who, csrf) = match &app.signin {
        Signin::Dev(who) => (Some(who.clone()), Some(app.csrf.clone())),
        Signin::Oidc(_) if let Some(token) = bearer(req.headers()) => {
            let a = app.clone();
            let checked = tokio::task::spawn_blocking(move || match &a.signin {
                Signin::Oidc(o) => o.bearer(&token),
                Signin::Dev(_) => unreachable!("matched above"),
            })
            .await
            .expect("token check thread");
            match checked {
                Ok(who) => (Some(who), None),
                Err(Refused::Bad(m)) => return problem(true, StatusCode::UNAUTHORIZED, &m),
                Err(Refused::NotAllowed(m)) => return problem(true, StatusCode::FORBIDDEN, &m),
            }
        }
        Signin::Oidc(o) => {
            let id = session_cookie(req.headers());
            (
                id.and_then(|id| o.session(id)),
                id.and_then(|id| o.csrf(id)),
            )
        }
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
    req.extensions_mut().insert(Csrf(csrf.unwrap_or_default()));
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

#[allow(clippy::too_many_arguments)]
async fn module(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
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
    let edit = edit_view(&app, &who, &csrf, &name, &sys, q.get("draft").cloned());
    let page = pages::module(
        &app,
        &who,
        &name,
        &sys,
        &module,
        &options,
        selected.as_ref(),
        edit.as_ref(),
    );
    page.into_response()
}

/// The system, what changed, and the candidate's open operations (none without a journal).
type ChangesView = (
    System,
    Vec<Change>,
    Option<Vec<golconda_core::candidate::Op>>,
);

async fn changes(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Response {
    let json = wants_json(&headers);
    let Some(doc) = app.document(&name).cloned() else {
        return problem(json, StatusCode::NOT_FOUND, &format!("no system {name}"));
    };
    let shared = app.clone();
    let system = name.clone();
    // with a journal: the candidate against the commit; without: the working tree against HEAD
    let done = tokio::task::spawn_blocking(move || -> Result<ChangesView, String> {
        let Some(writes) = &shared.writes else {
            let (sys, changes) = against_git(&shared.iets, &doc, "HEAD", &shared.platform)
                .map_err(|e| e.to_string())?;
            return Ok((sys, changes, None));
        };
        let sys = System::load(&shared.iets, &doc, &shared.platform).map_err(|e| e.to_string())?;
        let (ops, text) = {
            let journal = locked(&writes.journal);
            let ops = journal.open_ops(&system).map_err(|e| e.to_string())?;
            (
                ops,
                journal
                    .candidate(&system, &sys.text)
                    .map_err(|e| e.to_string())?,
            )
        };
        let changes = if ops.is_empty() {
            Vec::new()
        } else {
            let cand = System::load_text(&shared.iets, &doc, &text, &shared.platform)
                .map_err(|e| e.to_string())?;
            golconda_core::diff::diff(&sys.config, &cand.config)
        };
        Ok((sys, changes, Some(ops)))
    })
    .await
    .expect("evaluation thread");
    let (sys, changes, ops) = match done {
        Ok(view) => view,
        Err(e) => return problem(json, StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let diff = Value::Array(changes.iter().map(Change::to_json).collect());
    if json {
        return match &ops {
            None => axum::Json(diff).into_response(),
            Some(ops) => axum::Json(serde_json::json!({
                "ops": ops.iter().map(golconda_core::candidate::Op::to_json).collect::<Vec<_>>(),
                "changes": diff,
            }))
            .into_response(),
        };
    }
    let edit = edit_view(&app, &who, &csrf, &name, &sys, None);
    pages::changes(
        &app,
        &who,
        &name,
        &sys,
        &changes,
        ops.as_deref(),
        edit.as_ref(),
    )
    .into_response()
}

/// A request body as JSON: a JSON body as it is, a form's fields as an object of strings.
fn body_json(h: &HeaderMap, body: &[u8]) -> Result<Value, String> {
    let ctype = h
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if ctype.starts_with("application/json") {
        return serde_json::from_slice(body).map_err(|e| format!("the body is not JSON: {e}"));
    }
    if ctype.starts_with("application/x-www-form-urlencoded") {
        let pairs: Vec<(String, String)> =
            serde_urlencoded::from_bytes(body).map_err(|e| format!("the form: {e}"))?;
        return Ok(Value::Object(
            pairs
                .into_iter()
                .map(|(k, v)| (k, Value::String(v)))
                .collect(),
        ));
    }
    Err("send JSON or a form".into())
}

/// The answer to a write, as JSON.
fn outcome(o: write::Outcome) -> Response {
    let (status, v) = match o {
        Outcome::Done(v) => (StatusCode::OK, v),
        Outcome::Denied(m) => (StatusCode::FORBIDDEN, serde_json::json!({ "error": m })),
        Outcome::Conflict { yours, theirs } => (
            StatusCode::CONFLICT,
            serde_json::json!({ "error": "conflict", "yours": yours,
                "theirs": theirs.iter().map(golconda_core::candidate::Op::to_json).collect::<Vec<_>>() }),
        ),
        Outcome::Invalid(p) => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({ "error": "invalid", "problems": p.iter().map(|p| serde_json::json!({
                "line": p.line, "path": p.path, "message": p.message })).collect::<Vec<_>>() }),
        ),
        Outcome::Bad(m) => (StatusCode::BAD_REQUEST, serde_json::json!({ "error": m })),
        Outcome::Locked(l) => (
            StatusCode::LOCKED,
            serde_json::json!({ "error": "locked", "lock": l }),
        ),
        Outcome::Failed(m) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            serde_json::json!({ "error": m }),
        ),
    };
    (status, axum::Json(v)).into_response()
}

/// A form's POST is this site's own: it carries the session's CSRF token, and an Origin the
/// browser sent is the Host it sent. (A JSON POST needs neither: a page elsewhere cannot send
/// one without CORS, which this daemon does not answer.)
fn own_form(h: &HeaderMap, v: &Value, csrf: &str) -> bool {
    let token = v["csrf"].as_str().unwrap_or("");
    // in constant time: how much of a guess was right shows in no timing
    let same = token.len() == csrf.len()
        && token
            .bytes()
            .zip(csrf.bytes())
            .fold(0u8, |d, (a, b)| d | (a ^ b))
            == 0;
    let origin = match h.get(header::ORIGIN).and_then(|o| o.to_str().ok()) {
        None => true,
        Some(o) => {
            let authority = o.split_once("://").map_or(o, |(_, a)| a);
            h.get(header::HOST).and_then(|x| x.to_str().ok()) == Some(authority)
        }
    };
    !csrf.is_empty() && same && origin
}

fn is_form(h: &HeaderMap) -> bool {
    h.get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|c| c.starts_with("application/x-www-form-urlencoded"))
}

/// The answer to a form: back where it came from, or a page that says why not.
fn form_outcome(
    app: &App,
    who: &Identity,
    name: &str,
    form: &Value,
    o: write::Outcome,
) -> Response {
    let back = auth::safe_next(form["return"].as_str().unwrap_or("/"));
    match o {
        Outcome::Done(_) => Redirect::to(&back).into_response(),
        Outcome::Conflict { yours, theirs } => {
            let revision = app
                .writes
                .as_ref()
                .and_then(|w| locked(&w.journal).revision(name).ok())
                .unwrap_or(0);
            let page = pages::conflict(app, who, name, form, &yours, &theirs, revision, &back);
            (StatusCode::CONFLICT, page).into_response()
        }
        Outcome::Invalid(p) => {
            (StatusCode::UNPROCESSABLE_ENTITY, pages::problems(&back, &p)).into_response()
        }
        Outcome::Denied(m) => problem(false, StatusCode::FORBIDDEN, &m),
        Outcome::Bad(m) => problem(false, StatusCode::BAD_REQUEST, &m),
        Outcome::Locked(l) => problem(
            false,
            StatusCode::LOCKED,
            &format!(
                "{} holds the lock on this system until {}: ask them, or break it with a reason on the Changes page",
                l["by"]["name"].as_str().unwrap_or("someone"),
                l["until"].as_str().unwrap_or("?")
            ),
        ),
        Outcome::Failed(m) => problem(false, StatusCode::INTERNAL_SERVER_ERROR, &m),
    }
}

/// Run a write off the async threads (evaluation, git, SQLite), for a system that exists, on a
/// daemon that writes. A form gets a form's answer, JSON a JSON one.
async fn write(
    app: Shared,
    name: String,
    form: Option<(Identity, Value)>,
    f: impl FnOnce(&App, &write::Writes, &FsPath) -> write::Outcome + Send + 'static,
) -> Response {
    let Some(doc) = app.document(&name).cloned() else {
        return problem(
            form.is_none(),
            StatusCode::NOT_FOUND,
            &format!("no system {name}"),
        );
    };
    if app.writes.is_none() {
        let m = "this daemon only reads: it has no --state".to_string();
        return problem(form.is_none(), StatusCode::SERVICE_UNAVAILABLE, &m);
    }
    let a = app.clone();
    let done =
        tokio::task::spawn_blocking(move || f(&a, a.writes.as_ref().expect("checked"), &doc))
            .await
            .expect("write thread");
    match form {
        Some((who, v)) => form_outcome(&app, &who, &name, &v, done),
        None => outcome(done),
    }
}

fn via(h: &HeaderMap) -> &'static str {
    if wants_json(h) { "cli" } else { "web" }
}

/// A write's body, and for a form, the form: refused (403) unless it is this site's own. A
/// control's value becomes TOML (write::form_value).
#[allow(clippy::result_large_err)]
fn write_body(
    h: &HeaderMap,
    body: &[u8],
    who: &Identity,
    csrf: &Csrf,
) -> Result<(Value, Option<(Identity, Value)>), Response> {
    let mut v = body_json(h, body).map_err(|e| problem(true, StatusCode::BAD_REQUEST, &e))?;
    if !is_form(h) {
        return Ok((v, None));
    }
    if !own_form(h, &v, &csrf.0) {
        let m = "this form is not from this console's page: reload it and send it again";
        return Err(problem(false, StatusCode::FORBIDDEN, m));
    }
    if let (Some(kind), Some(raw)) = (
        v["kind"].as_str().map(str::to_string),
        v["value"].as_str().map(str::to_string),
    ) {
        v["value"] = Value::String(write::form_value(&kind, &raw));
    }
    Ok((v.clone(), Some((who.clone(), v))))
}

async fn write_op(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (v, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(r) => return r,
    };
    let via = via(&h);
    let system = name.clone();
    write(app, name, form, move |app, w, doc| {
        write::operation(app, w, &who, via, &system, doc, &v)
    })
    .await
}

async fn write_commit(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (v, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(r) => return r,
    };
    let message = v["message"].as_str().unwrap_or("").to_string();
    let via = via(&h);
    let system = name.clone();
    write(app, name, form, move |app, w, doc| {
        write::commit(app, w, &who, via, &system, doc, &message)
    })
    .await
}

async fn write_discard(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (_, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(r) => return r,
    };
    let via = via(&h);
    let system = name.clone();
    write(app, name, form, move |app, w, _| {
        write::discard(app, w, &who, via, &system)
    })
    .await
}

/// What a page needs to offer forms: none when this person may not write here.
fn edit_view(
    app: &App,
    who: &Identity,
    csrf: &Csrf,
    name: &str,
    sys: &System,
    draft: Option<String>,
) -> Option<pages::EditView> {
    let w = app.writes.as_ref()?;
    if app.read_only || who.level != Level::Operator {
        return None;
    }
    let j = locked(&w.journal);
    Some(pages::EditView {
        revision: j.revision(name).ok()?,
        csrf: csrf.0.clone(),
        candidate: golconda_core::document::to_json(&j.candidate(name, &sys.text).ok()?)
            .unwrap_or(Value::Null),
        ops: j.open_ops(name).ok()?,
        draft,
    })
}

/// The audit log, newest first, filtered by the query's operator, system, action and day.
async fn audit_log(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Query(q): Query<HashMap<String, String>>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    if app.writes.is_none() {
        return problem(
            json,
            StatusCode::NOT_FOUND,
            "this daemon keeps no audit log: it has no --state",
        );
    }
    let f = |k: &str| {
        q.get(k)
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let filter = golconda_core::audit::Filter {
        operator: f("operator"),
        system: f("system"),
        action: f("action"),
        day: f("day"),
    };
    let a = app.clone();
    let entries = tokio::task::spawn_blocking(move || {
        a.writes
            .as_ref()
            .map(|w| w.entries(&filter, 500))
            .unwrap_or_default()
    })
    .await
    .expect("audit thread");
    if json {
        return axum::Json(Value::Array(entries)).into_response();
    }
    pages::audit(&app, &who, &entries, &q).into_response()
}

/// The candidate: its revision and the operations not yet committed.
async fn candidate(State(app): State<Shared>, Path(name): Path<String>) -> Response {
    if app.document(&name).is_none() {
        return problem(true, StatusCode::NOT_FOUND, &format!("no system {name}"));
    }
    if app.writes.is_none() {
        return axum::Json(serde_json::json!({ "revision": 0, "ops": [] })).into_response();
    }
    let a = app.clone();
    let read = tokio::task::spawn_blocking(move || {
        let j = locked(&a.writes.as_ref().expect("checked").journal);
        let text = |e: &dyn fmt::Display| e.to_string();
        Ok::<_, String>(serde_json::json!({
            "revision": j.revision(&name).map_err(|e| text(&e))?,
            "ops": j.open_ops(&name).map_err(|e| text(&e))?.iter().map(golconda_core::candidate::Op::to_json).collect::<Vec<_>>(),
            "lock": j.lock_of(&name).map_err(|e| text(&e))?.as_ref().map(golconda_core::candidate::Lock::to_json),
        }))
    })
    .await
    .expect("journal thread");
    match read {
        Ok(v) => axum::Json(v).into_response(),
        Err(e) => problem(true, StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
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

async fn script() -> Response {
    (
        [
            (
                header::CONTENT_TYPE,
                "application/javascript; charset=utf-8",
            ),
            (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
        ],
        include_str!("live.js"),
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

/// A system's machines, read over ssh at once (each a few varlink calls).
async fn machines(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    let Some(doc) = app.document(&name).cloned() else {
        return problem(json, StatusCode::NOT_FOUND, &format!("no system {name}"));
    };
    let (a, n) = (app.clone(), name.clone());
    let read = tokio::task::spawn_blocking(move || -> Result<_, String> {
        let fleet = jobs::fleet(&doc, &n)?;
        let ssh = a.jobs.as_ref().map_or_else(
            || golconda_core::vars::Program::from_env("GOLCONDA_SSH", "ssh"),
            |r| r.config.ssh.clone(),
        );
        let views: Vec<pages::MachineView> = thread::scope(|s| {
            let handles: Vec<_> = fleet
                .machines
                .values()
                .map(|m| {
                    let ssh = &ssh;
                    s.spawn(move || pages::MachineView {
                        machine: m.clone(),
                        status: golconda_core::machine::Remote { ssh }
                            .status(m)
                            .map_err(|e| e.0),
                    })
                })
                .collect();
            handles.into_iter().filter_map(|h| h.join().ok()).collect()
        });
        let recent: Vec<golconda_core::jobs::Job> = a
            .jobs
            .as_ref()
            .and_then(|r| locked(&r.store).list(Some(&n), 10).ok())
            .unwrap_or_default();
        let keys = a
            .jobs
            .as_ref()
            .is_some_and(|r| r.config.release_keys.is_some());
        Ok(pages::StatusView {
            deploys: keys && fleet.updates.is_some() && !fleet.machines.is_empty(),
            updates: fleet.updates,
            machines: views,
            recent,
        })
    })
    .await
    .expect("machine thread");
    let view = match read {
        Ok(x) => x,
        Err(e) => return problem(json, StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    if json {
        let ms: Vec<Value> = view
            .machines
            .iter()
            .map(|v| match &v.status {
                Ok(st) => serde_json::json!({ "name": v.machine.name, "ssh": v.machine.ssh, "status": st.to_json() }),
                Err(e) => serde_json::json!({ "name": v.machine.name, "ssh": v.machine.ssh, "error": e }),
            })
            .collect();
        return axum::Json(serde_json::json!({ "updates": view.updates, "machines": ms }))
            .into_response();
    }
    let sys = match load(&app, &name, false).await {
        Ok(s) => s,
        Err(r) => return *r,
    };
    let may = app.jobs.is_some() && !app.read_only && who.level == Level::Operator;
    let c = may.then_some(csrf.0.as_str());
    pages::status(&app, &who, &name, &sys, &view, c).into_response()
}

/// Start a job: { kind, machine } as JSON or a form's fields. A form goes on to the job's page.
async fn start_job(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (asked, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(refused) => return refused,
    };
    let via = via(&h);
    let shared = app.clone();
    let done = tokio::task::spawn_blocking(move || {
        let kind = asked["kind"].as_str().unwrap_or("");
        jobs::submit(&shared, &who, via, &name, kind, asked["machine"].as_str())
    })
    .await
    .expect("job thread");
    match (form, done) {
        (Some(_), Outcome::Done(started)) => {
            Redirect::to(&format!("/jobs/{}", started["job"])).into_response()
        }
        (Some(_), Outcome::Denied(m)) => problem(false, StatusCode::FORBIDDEN, &m),
        (Some(_), Outcome::Bad(m)) => problem(false, StatusCode::BAD_REQUEST, &m),
        (_, other) => outcome(other),
    }
}

async fn job_list(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Query(q): Query<HashMap<String, String>>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    if app.jobs.is_none() {
        return problem(json, StatusCode::NOT_FOUND, "this daemon runs no jobs");
    }
    let (a, system) = (app.clone(), q.get("system").cloned());
    let list = tokio::task::spawn_blocking(move || {
        a.jobs
            .as_ref()
            .and_then(|r| locked(&r.store).list(system.as_deref(), 100).ok())
            .unwrap_or_default()
    })
    .await
    .expect("job thread");
    if json {
        let v: Vec<Value> = list.iter().map(golconda_core::jobs::Job::to_json).collect();
        return axum::Json(Value::Array(v)).into_response();
    }
    pages::jobs(&app, &who, &list).into_response()
}

/// One job and its output; `?after=N` in JSON: only the lines after line N.
async fn job_page(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Path(id): Path<i64>,
    Query(q): Query<HashMap<String, String>>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    if app.jobs.is_none() {
        return problem(json, StatusCode::NOT_FOUND, "this daemon runs no jobs");
    }
    let after = q.get("after").and_then(|a| a.parse().ok()).unwrap_or(0);
    let a = app.clone();
    let found = tokio::task::spawn_blocking(move || {
        let store = locked(&a.jobs.as_ref().expect("checked").store);
        store
            .get(id)
            .map(|j| (j, store.lines(id, after).unwrap_or_default()))
            .map_err(|e| e.to_string())
    })
    .await
    .expect("job thread");
    let (job, lines) = match found {
        Ok(x) => x,
        Err(e) => return problem(json, StatusCode::NOT_FOUND, &e),
    };
    if json {
        let ls: Vec<Value> = lines
            .iter()
            .map(|(n, at, l)| serde_json::json!({ "n": n, "at": at, "line": l }))
            .collect();
        return axum::Json(serde_json::json!({ "job": job.to_json(), "lines": ls }))
            .into_response();
    }
    pages::job(&app, &who, &job, &lines).into_response()
}

/// The SBOM of a system, evaluated (0.3 s), off the async threads.
async fn bom_of(
    app: &Shared,
    name: &str,
    json: bool,
) -> Result<golconda_core::packages::Packages, Box<Response>> {
    let Some(doc) = app.document(name).cloned() else {
        return Err(Box::new(problem(
            json,
            StatusCode::NOT_FOUND,
            &format!("no system {name}"),
        )));
    };
    let a = app.clone();
    tokio::task::spawn_blocking(move || golconda_core::packages::load(&a.iets, &doc, &a.platform))
        .await
        .expect("evaluation thread")
        .map_err(|e| {
            Box::new(problem(
                json,
                StatusCode::INTERNAL_SERVER_ERROR,
                &e.to_string(),
            ))
        })
}

async fn packages(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Path(name): Path<String>,
    h: HeaderMap,
) -> Response {
    let json = wants_json(&h);
    let p = match bom_of(&app, &name, json).await {
        Ok(p) => p,
        Err(r) => return *r,
    };
    if json {
        let v: Vec<Value> = p
            .list
            .iter()
            .map(golconda_core::packages::Package::to_json)
            .collect();
        return axum::Json(Value::Array(v)).into_response();
    }
    let sys = match load(&app, &name, false).await {
        Ok(s) => s,
        Err(r) => return *r,
    };
    pages::packages(&app, &who, &name, &sys, &p.list).into_response()
}

/// The CycloneDX document itself.
async fn sbom(State(app): State<Shared>, Path(name): Path<String>) -> Response {
    match bom_of(&app, &name, true).await {
        Ok(p) => axum::Json(p.bom).into_response(),
        Err(r) => *r,
    }
}

/// Take or extend the lock: { minutes } (30 without).
async fn write_lock(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (asked, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(refused) => return refused,
    };
    let minutes = match &asked["minutes"] {
        Value::Number(n) => n.as_u64(),
        Value::String(t) => t.parse().ok(),
        _ => Some(30),
    }
    .unwrap_or(30)
    .clamp(1, 24 * 60);
    let via = via(&h);
    let system = name.clone();
    write(app, name, form, move |app, w, _| {
        write::lock(app, w, &who, via, &system, minutes)
    })
    .await
}

async fn write_unlock(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (_, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(refused) => return refused,
    };
    let via = via(&h);
    let system = name.clone();
    write(app, name, form, move |app, w, _| {
        write::unlock(app, w, &who, via, &system)
    })
    .await
}

/// Break whoever's lock: { reason }.
async fn write_break_lock(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Extension(csrf): Extension<Csrf>,
    Path(name): Path<String>,
    h: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let (asked, form) = match write_body(&h, &body, &who, &csrf) {
        Ok(x) => x,
        Err(refused) => return refused,
    };
    let reason = asked["reason"].as_str().unwrap_or("").to_string();
    let via = via(&h);
    let system = name.clone();
    write(app, name, form, move |app, w, _| {
        write::break_lock(app, w, &who, via, &system, &reason)
    })
    .await
}

/// Leaves the presence when the stream ends, however it ends.
struct Watching {
    app: Shared,
    id: u64,
}

impl Drop for Watching {
    fn drop(&mut self) {
        self.app.events.leave(self.id);
    }
}

/// The system's live updates as Server-Sent Events; `?page=` names the page that listens.
async fn live(
    State(app): State<Shared>,
    Extension(who): Extension<Identity>,
    Path(name): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    if app.document(&name).is_none() {
        return problem(true, StatusCode::NOT_FOUND, &format!("no system {name}"));
    }
    let page = auth::safe_next(q.get("page").map_or("/", String::as_str));
    let (id, rx) = app.events.join(&name, &who, &page);
    let watching = Watching {
        app: app.clone(),
        id,
    };
    let stream = stream::unfold((rx, watching, name), |(mut rx, w, name)| async move {
        loop {
            match rx.recv().await {
                Ok(e) if e.system == name => {
                    let sse = SseEvent::default().event(e.kind).data(e.data.to_string());
                    return Some((Ok::<_, Infallible>(sse), (rx, w, name)));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    });
    Sse::new(stream)
        .keep_alive(KeepAlive::default())
        .into_response()
}
