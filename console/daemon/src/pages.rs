//! The pages, server-rendered (maud escapes every value). No script and no request to
//! another origin: a page is complete without either.

use crate::app::{App, Identity, Level, Signin};
use crate::locked;
use axum::http::StatusCode;
use golconda_core::candidate::{Lock, Op};
use golconda_core::diff::Change;
use golconda_core::document::{option_name, toml_text};
use golconda_core::jobs::State;
use golconda_core::packages::Package;
use golconda_core::system::{Explanation, System};
use maud::{DOCTYPE, Markup, PreEscaped, html};
use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use serde_json::Value;
use std::collections;
use std::hash::BuildHasher;
use std::path::PathBuf;

#[derive(PartialEq, Clone, Copy)]
enum Tab {
    Config,
    Changes,
    Status,
    Packages,
}

/// The frame: the strip (system, image, who), the read-only banner, the rail.
fn layout(
    app: &App,
    who: &Identity,
    system: Option<(&str, &System)>,
    tab: Option<Tab>,
    title: &str,
    main: &Markup,
) -> Markup {
    let version = system.and_then(|(_, s)| s.config["/system"]["version"]["value"].as_str());
    html! {
        (DOCTYPE)
        html lang="en" {
            head {
                meta charset="utf-8";
                meta name="viewport" content="width=device-width, initial-scale=1";
                title { (title) " · golconda" }
                link rel="stylesheet" href=(stylesheet());
            }
            body {
                div.app {
                    div.strip {
                        span.host { (system.map_or("golconda", |(n, _)| n)) }
                        @if let Some(v) = version { span.pill.p-grey { "image " (v) } }
                        @if let Some(l) = system.and_then(|(n, _)| lock_of(app, n)) {
                            span.pill.p-amber { "locked by " (l.by.name) " until " (l.until_text()) }
                        }
                        span.cr {
                            @if app.read_only || who.level == Level::ReadOnly {
                                span.pill.p-amber { "read-only" }
                            }
                            span.pill.p-sky { (who.name) " · " (who.level.name()) }
                            @if let Signin::Oidc(_) = app.signin {
                                form method="post" action="/auth/logout" { button.link { "Sign out" } }
                            }
                        }
                    }
                    @if app.read_only {
                        div.banner.amber { "This console is read-only: it shows state and changes nothing." }
                    }
                    @if app.writes.as_ref().is_some_and(|w| w.audit_unpushed.load(std::sync::atomic::Ordering::SeqCst)) {
                        div.banner.red { "The audit log has entries its remote does not have yet: the daemon keeps trying to push them." }
                    }
                    div.body {
                        nav.rail {
                            @if let Some((name, _)) = system {
                                a class=[(tab == Some(Tab::Config)).then_some("on")] href={ "/systems/" (name) "/config" } { "Configuration" }
                                a class=[(tab == Some(Tab::Changes)).then_some("on")] href={ "/systems/" (name) "/changes" } {
                                    "Changes"
                                    @if let Some(n) = open_count(app, name) { small { (n) } }
                                }
                                a class=[(tab == Some(Tab::Status)).then_some("on")] href={ "/systems/" (name) "/machines" } { "Status" }
                                a class=[(tab == Some(Tab::Packages)).then_some("on")] href={ "/systems/" (name) "/packages" } { "Packages" }
                            }
                            // the system's pages first, the daemon's own after them
                            @if app.jobs.is_some() {
                                a class=[(title == "Jobs" || title.starts_with("Job ")).then_some("on")] href="/jobs" { "Jobs" }
                            }
                            @if app.writes.is_some() {
                                a class=[(title == "Audit log").then_some("on")] href="/audit" { "Audit log" }
                            }
                        }
                        main.main { (main) }
                    }
                }
            }
        }
    }
}

/// The system's lock, while it lasts.
fn lock_of(app: &App, name: &str) -> Option<Lock> {
    let w = app.writes.as_ref()?;
    locked(&w.journal).lock_of(name).ok()?
}

/// The Changes page's lock section: who holds it, and the forms to take, give up or break it.
fn lock_box(app: &App, who: &Identity, name: &str, ev: &EditView) -> Markup {
    let back = format!("/systems/{name}/changes");
    let lock = lock_of(app, name);
    html! {
        h3 { "Lock" }
        @match &lock {
            None => {
                p { "Nobody holds the lock: everyone may change the candidate." }
                form.inline method="post" action={ "/systems/" (name) "/lock" } {
                    input type="hidden" name="csrf" value=(ev.csrf);
                    input type="hidden" name="return" value=(back);
                    select name="minutes" {
                        @for m in [15, 30, 60, 120, 240] { option value=(m) selected[m == 30] { (m) " minutes" } }
                    }
                    " " button.btn type="submit" { "Lock" }
                }
            }
            Some(l) if l.by.id == who.id => {
                p { "You hold the lock since " (l.since) " until " (l.until_text()) ": only you change the candidate." }
                form.inline method="post" action={ "/systems/" (name) "/unlock" } {
                    input type="hidden" name="csrf" value=(ev.csrf);
                    input type="hidden" name="return" value=(back);
                    button.btn type="submit" { "Unlock" }
                }
            }
            Some(l) => {
                p { (l.by.name) " holds the lock since " (l.since) " until " (l.until_text()) ": only they change the candidate." }
                form.field method="post" action={ "/systems/" (name) "/lock/break" } {
                    input type="hidden" name="csrf" value=(ev.csrf);
                    input type="hidden" name="return" value=(back);
                    label { "Why break it (the audit log keeps it)" }
                    input type="text" name="reason" required;
                    div.row { button.btn type="submit" { "Break the lock" } }
                }
            }
        }
    }
}

/// The number of operations a system's candidate has open, when it has any.
fn open_count(app: &App, name: &str) -> Option<usize> {
    let w = app.writes.as_ref()?;
    let n = locked(&w.journal).open_ops(name).ok()?.len();
    (n > 0).then_some(n)
}

pub fn index(app: &App, who: &Identity, systems: &[(String, PathBuf)]) -> Markup {
    let main = html! {
        h2 { "Systems" }
        table {
            tr { th { "system" } th { "document" } }
            @for (name, doc) in systems {
                tr {
                    td { a href={ "/systems/" (name) "/config" } { (name) } }
                    td.m { (doc.display()) }
                }
            }
        }
    };
    layout(app, who, None, None, "Systems", &main)
}

pub fn problem(status: StatusCode, message: &str) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            head {
                meta charset="utf-8";
                title { (status.as_u16()) " · golconda" }
                link rel="stylesheet" href=(stylesheet());
            }
            body { div.app { div.body { div.rail {} main.main {
                h2 { (status) }
                div.err { (message) }
            } } } }
        }
    }
}

/// The module tree: every module of the schema; one the system does not include greyed.
fn tree(name: &str, sys: &System, current: Option<&str>) -> Markup {
    let modules: Vec<&String> = sys.schema["properties"]
        .as_object()
        .map(|m| m.keys().filter(|k| k.starts_with('/')).collect())
        .unwrap_or_default();
    html! {
        div.tree {
            @for m in modules {
                @let included = sys.config.get(m.as_str()).is_some();
                @let class = match (current == Some(m.as_str()), included) {
                    (true, _) => Some("on"),
                    (false, false) => Some("ghost"),
                    (false, true) => None,
                };
                div class=[class] {
                    a href={ "/systems/" (name) "/config" (m) } { (m) }
                    @if !included { small { "not included" } }
                }
            }
        }
    }
}

/// A module's doc: its first paragraph, and the rest.
fn split_doc(doc: &str) -> (&str, &str) {
    doc.split_once("\n\n").unwrap_or((doc, ""))
}

/// Markdown (module docs, option descriptions) as HTML. Raw HTML in it is shown as text,
/// images are left out (they would load from elsewhere), and a link stays a link only to
/// http(s); any other link is its text. `inline`: no paragraph around a single line.
pub fn markdown(text: &str, inline: bool) -> Markup {
    // for each open link: whether it is kept
    let mut links = Vec::new();
    let options =
        pulldown_cmark::Options::ENABLE_TABLES | pulldown_cmark::Options::ENABLE_STRIKETHROUGH;
    let events = Parser::new_ext(text, options).filter_map(|e| match e {
        Event::Html(h) | Event::InlineHtml(h) => Some(Event::Text(h)),
        Event::Start(Tag::Image { .. }) | Event::End(TagEnd::Image) => None,
        Event::Start(Tag::Link { ref dest_url, .. }) => {
            let ok = dest_url.starts_with("https://") || dest_url.starts_with("http://");
            links.push(ok);
            ok.then_some(e)
        }
        Event::End(TagEnd::Link) => links.pop().unwrap_or(false).then_some(e),
        Event::Start(Tag::Paragraph) | Event::End(TagEnd::Paragraph) if inline => None,
        e => Some(e),
    });
    let mut out = String::new();
    pulldown_cmark::html::push_html(&mut out, events);
    PreEscaped(out)
}

pub fn config(app: &App, who: &Identity, name: &str, sys: &System) -> Markup {
    let main = html! {
        div.three {
            (tree(name, sys, None))
            div {
                h2 { "Modules" }
                @for (m, doc) in sys.module_docs.as_object().into_iter().flatten() {
                    a.opt href={ "/systems/" (name) "/config" (m) } {
                        span.n { (m) }
                        span.v.def { @if sys.config.get(m.as_str()).is_none() { "not included" } }
                        @if let Some(d) = doc.as_str() { span.desc { (markdown(split_doc(d).0, true)) } }
                    }
                }
            }
            div.detail { p.empty { "Choose a module." } }
        }
    };
    layout(
        app,
        who,
        Some((name, sys)),
        Some(Tab::Config),
        "Configuration",
        &main,
    )
}

fn count(n: usize, what: &str) -> String {
    if n == 1 {
        format!("1 {what}")
    } else {
        format!("{n} {what}s")
    }
}

/// The stylesheet's address, with a hash of its content: it is cached for a year, and a new
/// stylesheet is a new address.
pub fn stylesheet() -> String {
    let hash = include_str!("style.css")
        .bytes()
        .fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
        });
    format!("/assets/style.css?v={hash:016x}")
}

/// A value short enough for a row: its TOML, or a count.
pub fn summary(v: &Value) -> String {
    let t = toml_text(v);
    if t.chars().count() <= 40 {
        return t;
    }
    match v {
        Value::Array(xs) => format!("[{}]", count(xs.len(), "item")),
        Value::Object(m) => format!("{{{}}}", count(m.len(), "key")),
        _ => format!("{}…", t.chars().take(39).collect::<String>()),
    }
}

/// What a page needs for its forms, when the person may write: the candidate's revision (the
/// base of a change), its document as JSON, its open operations, the session's CSRF token, and
/// a draft value (TOML) to put back in the form ("edit again" on the conflict page).
pub struct EditView {
    pub revision: u64,
    pub csrf: String,
    pub candidate: Value,
    pub ops: Vec<Op>,
    pub draft: Option<String>,
}

impl EditView {
    /// The candidate's value at `module` `path`: None when the document does not set it.
    fn value(&self, module: &str, path: &[&str]) -> Option<&Value> {
        path.iter()
            .try_fold(self.candidate.get(module)?, |v, k| v.get(*k))
    }

    /// An open operation touches this option.
    fn changed(&self, module: &str, option: &str) -> bool {
        self.ops
            .iter()
            .any(|o| o.module == module && (o.path.is_empty() || o.path[0] == option))
    }
}

#[allow(clippy::too_many_arguments)]
pub fn module(
    app: &App,
    who: &Identity,
    name: &str,
    sys: &System,
    module: &str,
    options: &[Explanation],
    selected: Option<&Explanation>,
    edit: Option<&EditView>,
) -> Markup {
    let file = options
        .iter()
        .find_map(|o| o.declared_at.as_ref().map(|(f, _)| f.clone()));
    let doc = sys.module_docs[module].as_str();
    let main = html! {
        div.three {
            (tree(name, sys, Some(module)))
            div {
                div.modhead {
                    h2 { (module) }
                    @if let Some(f) = &file { span { (f) } }
                }
                @if let Some(d) = doc {
                    @let (first, rest) = split_doc(d);
                    div.doc.md { (markdown(first, false)) }
                    @if !rest.is_empty() {
                        details.doc { summary { "More about " (module) } div.doc.md { (markdown(rest, false)) } }
                    }
                }
                @if sys.config.get(module).is_none() {
                    p.doc { "This system does not include " (module) "." }
                }
                @if options.is_empty() {
                    p.doc { "This module has no options." }
                }
                @for o in options {
                    a.opt.on[selected.is_some_and(|s| s.option == o.option)]
                        id=(o.option) href={ "?option=" (o.option) "#" (o.option) } {
                        span.n { (o.option) }
                        @if let Some(e) = edit.filter(|e| e.changed(module, &o.option)) {
                            // changed in the candidate, not committed: its value there
                            span.v.chg {
                                (e.value(module, &[o.option.as_str()]).map_or("none".into(), summary))
                                " " span.was { "(was " (o.value.as_ref().map_or("none".into(), summary)) ")" }
                            }
                        } @else {
                            @match &o.value {
                                Some(v) => span class={ "v " (if o.explicit { "set" } else { "def" }) } { (summary(v)) },
                                None => span.v.def { "none" },
                            }
                        }
                        @if let Some(d) = &o.description { span.desc { (markdown(d, true)) } }
                    }
                }
                div.legend {
                    "default" " · " span.set { "set in " (sys.document.display()) }
                    @if edit.is_some() { " · " span.chg { "changed, not committed" } }
                }
            }
            div.detail {
                @match selected {
                    Some(e) => { (detail(e, edit)) @if let Some(ev) = edit { (form(name, sys, e, ev)) } },
                    None => p.empty { "Choose an option." },
                }
            }
        }
    };
    layout(
        app,
        who,
        Some((name, sys)),
        Some(Tab::Config),
        module,
        &main,
    )
}

fn detail(e: &Explanation, edit: Option<&EditView>) -> Markup {
    let path: Vec<&str> = e.option.split('.').collect();
    let candidate = edit
        .filter(|ev| ev.changed(&e.module, path[0]))
        .map(|ev| ev.value(&e.module, &path).map_or("none".into(), toml_text));
    html! {
        h4 { (e.module) " " (e.option) }
        @if let Some(d) = &e.description { div.md { (markdown(d, false)) } }
        dl {
            dt { "type" } dd { (e.type_name) }
            dt { "value" } dd { (e.value.as_ref().map_or("none".into(), toml_text)) }
            @if let Some(c) = candidate { dt { "candidate" } dd.chg { (c) } }
            @if let Some(d) = &e.default { dt { "default" } dd { (toml_text(d)) } }
            @if let Some((f, l)) = &e.declared_at { dt { "declared" } dd { (f) ":" (l) } }
            @if let Some((f, l)) = &e.set_at { dt { "in TOML" } dd { (f) ":" (l) } }
        }
    }
}

/// A control for a value of this schema node: what it shows, and how the daemon reads it back
/// (`kind`, write::form_value).
fn control(node: &Value, current: Option<&Value>) -> Markup {
    let strings = |v: &Value| v.as_array().is_some_and(|a| a.iter().all(Value::is_string));
    html! {
        @if node["type"] == "boolean" {
            input type="hidden" name="kind" value="toml";
            div.radio {
                label { input type="radio" name="value" value="true" checked[current == Some(&Value::Bool(true))]; " true" }
                label { input type="radio" name="value" value="false" checked[current == Some(&Value::Bool(false))]; " false" }
            }
        } @else if node["enum"].is_array() && strings(&node["enum"]) {
            input type="hidden" name="kind" value="string";
            select name="value" {
                @for v in node["enum"].as_array().into_iter().flatten() {
                    option value=(v.as_str().unwrap_or("")) selected[current == Some(v)] { (v.as_str().unwrap_or("")) }
                }
            }
        } @else if node["type"] == "integer" {
            input type="hidden" name="kind" value="toml";
            input type="number" name="value" required min=[node["minimum"].as_i64()] max=[node["maximum"].as_i64()]
                value=[current.map(std::string::ToString::to_string)];
        } @else if node["type"] == "string" {
            input type="hidden" name="kind" value="string";
            input type="text" name="value" value=[current.and_then(Value::as_str)];
        } @else if node["type"] == "array" && node["items"]["type"] == "string" {
            input type="hidden" name="kind" value="lines";
            textarea name="value" rows="4" {
                @for l in current.and_then(Value::as_array).into_iter().flatten() { (l.as_str().unwrap_or("")) "\n" }
            }
            small { "one per line" }
        } @else {
            input type="hidden" name="kind" value="toml";
            textarea name="value" rows="4" { (current.map_or(String::new(), toml_text)) }
            small { "TOML" }
        }
    }
}

/// The detail's forms: save a value to the candidate, reset to the default.
fn form(name: &str, sys: &System, e: &Explanation, ev: &EditView) -> Markup {
    let path: Vec<&str> = e.option.split('.').collect();
    let node = golconda_core::schema::option(&sys.schema, &e.module, &path)
        .map_or(Value::Null, |o| {
            golconda_core::schema::resolve(&sys.schema, o.node).clone()
        });
    let draft = ev
        .draft
        .as_deref()
        .and_then(|d| golconda_core::document::to_json(&format!("x = {d}")).ok())
        .map(|v| v["x"].clone());
    let current = draft
        .or_else(|| ev.value(&e.module, &path).cloned())
        .or_else(|| e.value.clone());
    let back = format!("/systems/{name}/config{}?option={}", e.module, e.option);
    let action = format!("/systems/{name}/ops");
    let hidden = |op: &str| {
        html! {
            input type="hidden" name="csrf" value=(ev.csrf);
            input type="hidden" name="base" value=(ev.revision);
            input type="hidden" name="module" value=(e.module);
            input type="hidden" name="option" value=(e.option);
            input type="hidden" name="op" value=(op);
            input type="hidden" name="return" value=(back);
        }
    };
    html! {
        form.field method="post" action=(action) {
            (hidden("set"))
            label { "Value" }
            (control(&node, current.as_ref()))
            div.row { button.btn.pri type="submit" { "Save to candidate" } }
        }
        @if ev.value(&e.module, &path).is_some() {
            form method="post" action=(action) {
                (hidden("delete"))
                button.btn type="submit" { "Reset to default" }
            }
        }
        p.empty { "Revision " (ev.revision) "; saved changes wait in the candidate until a commit." }
    }
}

/// A form's operation conflicted: yours, theirs, and three ways on.
#[allow(clippy::too_many_arguments)]
pub fn conflict(
    app: &App,
    who: &Identity,
    name: &str,
    form: &Value,
    yours: &Value,
    theirs: &[Op],
    revision: u64,
    back: &str,
) -> Markup {
    let value = form["value"].as_str().unwrap_or("");
    let edit_again = format!(
        "{back}{}draft={}",
        if back.contains('?') { '&' } else { '?' },
        crate::auth::encode(value)
    );
    let main = html! {
        h2 { "Conflict" }
        p.doc { "Since the page you sent this from, someone changed what it changes." }
        h3 { "Yours" }
        div.diff { span.add { (yours["target"].as_str().unwrap_or("")) " = " (value) } }
        h3 { "Theirs" }
        table {
            tr { th { "rev" } th { "change" } th { "who" } th { "when" } }
            @for o in theirs {
                tr { td.m { (o.rev) } td.m { (o.summary()) } td { (o.by.name) } td.m { (o.at) } }
            }
        }
        div.row.choices {
            a.btn href=(back) { "Keep theirs" }
            form method="post" action={ "/systems/" (name) "/ops" } {
                @for k in ["csrf", "module", "option", "op", "value", "return"] {
                    input type="hidden" name=(k) value=(form[k].as_str().unwrap_or(""));
                }
                input type="hidden" name="kind" value="toml";
                input type="hidden" name="base" value=(revision);
                button.btn.pri type="submit" { "Apply mine on top" }
            }
            a.btn href=(edit_again) { "Edit again" }
        }
    };
    layout(app, who, None, None, "Conflict", &main)
}

/// A form's operation would add problems the schema finds.
pub fn problems(back: &str, problems: &[golconda_core::check::Problem]) -> Markup {
    let lines: Vec<String> = problems
        .iter()
        .map(|p| {
            if p.path.is_empty() {
                p.message.clone()
            } else {
                format!("{}: {}", p.path, p.message)
            }
        })
        .collect();
    let mut page = problem(StatusCode::UNPROCESSABLE_ENTITY, &lines.join("\n")).into_string();
    page = page.replace(
        "</main>",
        &format!(
            "<p><a href=\"{}\">Back to the form</a></p></main>",
            maud::html! { (back) }.into_string()
        ),
    );
    PreEscaped(page)
}

/// The audit log: a filter form (GET, so it works without a script) and the entries.
pub fn audit<S: BuildHasher>(
    app: &App,
    who: &Identity,
    entries: &[Value],
    q: &collections::HashMap<String, String, S>,
) -> Markup {
    let field = |k: &str| q.get(k).cloned().unwrap_or_default();
    let result_class = |r: &str| match r {
        "ok" | "recorded" => "pill p-green",
        "refused" => "pill p-amber",
        _ => "pill p-red",
    };
    let main = html! {
        h2 { "Audit log" }
        form.filters method="get" action="/audit" {
            @for (k, label) in [("operator", "operator"), ("system", "system"), ("action", "action"), ("day", "day (2026-11-05)")] {
                div { label { (label) } input type="text" name=(k) value=(field(k)); }
            }
            div { button.btn type="submit" { "Filter" } }
        }
        @if entries.is_empty() {
            p { "No entries." }
        } @else {
            table.audit {
                tr { th { "time" } th { "operator" } th { "action" } th { "system" } th { "target" } th { "change" } th { "result" } }
                @for e in entries {
                    tr {
                        td.m { (e["time"].as_str().unwrap_or("")) }
                        td { (e["operator"]["name"].as_str().unwrap_or("")) " " small.m { (e["operator"]["via"].as_str().unwrap_or("")) } }
                        td.m { (e["action"].as_str().unwrap_or("")) }
                        td.m { (e["system"].as_str().unwrap_or("")) }
                        td.m { (e["target"].as_str().unwrap_or("")) }
                        td.m {
                            @if let Some(b) = e.get("before") { (toml_text(b)) " → " }
                            @if let Some(a) = e.get("after") { (toml_text(a)) }
                            @if let Some(c) = e["configCommit"].as_str() { "commit " (c.get(..10).unwrap_or(c)) }
                        }
                        td { span class=(result_class(e["result"].as_str().unwrap_or(""))) { (e["result"].as_str().unwrap_or("")) } }
                    }
                }
            }
        }
    };
    layout(app, who, None, None, "Audit log", &main)
}

/// The changes: on a daemon with a journal, the candidate's open operations and what they
/// change against the commit, with the commit and discard forms for an operator; without one,
/// the working tree against git's HEAD.
pub fn changes(
    app: &App,
    who: &Identity,
    name: &str,
    sys: &System,
    changes: &[Change],
    ops: Option<&[Op]>,
    edit: Option<&EditView>,
) -> Markup {
    let main = html! {
        h2 { "Changes" }
        @match ops {
            None => p.doc { (sys.document.display()) " in the working tree, against git's HEAD." },
            Some(ops) => {
                p.doc { "The candidate: what is saved and not committed, against the commit." }
                @if ops.is_empty() {
                    p { "No changes in the candidate." }
                } @else {
                    table {
                        tr { th { "rev" } th { "change" } th { "who" } th { "when" } }
                        @for o in ops {
                            tr { td.m { (o.rev) } td.m { (o.summary()) } td { (o.by.name) } td.m { (o.at) } }
                        }
                    }
                }
            }
        }
        @if changes.is_empty() {
            @if ops.is_none() { p { "No changes against HEAD." } }
        } @else {
            h3 { "What changes" }
            div.diff {
                @for (i, c) in changes.iter().enumerate() {
                    @if i == 0 || changes[i - 1].module != c.module { span.hdr { (c.module) } "\n" }
                    @let at = { let p: Vec<&str> = c.path.iter().map(String::as_str).collect(); if p.is_empty() { "(module)".to_string() } else { option_name(&p) } };
                    @if let Some(v) = &c.before.value {
                        span.del { "- " (at) " = " (toml_text(v)) @if !c.before.explicit { "  (default)" } } "\n"
                    }
                    @if let Some(v) = &c.after.value {
                        span.add { "+ " (at) " = " (toml_text(v)) @if !c.after.explicit { "  (default)" } } "\n"
                    }
                }
            }
        }
        @if let (Some(ev), Some(_)) = (edit, ops) { (lock_box(app, who, name, ev)) }
        @if let (Some(ev), Some(ops)) = (edit, ops) {
            @if !ops.is_empty() {
                form.field method="post" action={ "/systems/" (name) "/commit" } {
                    input type="hidden" name="csrf" value=(ev.csrf);
                    input type="hidden" name="return" value={ "/systems/" (name) "/changes" };
                    label { "Message" }
                    textarea name="message" rows="3" required {}
                    div.row { button.btn.pri type="submit" { "Commit and push" } }
                }
                form method="post" action={ "/systems/" (name) "/discard" } {
                    input type="hidden" name="csrf" value=(ev.csrf);
                    input type="hidden" name="return" value={ "/systems/" (name) "/changes" };
                    button.btn type="submit" { "Discard all" }
                }
            }
        }
    };
    layout(
        app,
        who,
        Some((name, sys)),
        Some(Tab::Changes),
        "Changes",
        &main,
    )
}

/// A form that starts a job: its kind, the machine, back to `back`.
fn job_form(name: &str, csrf: &str, kind: &str, machine: Option<&str>, label: &str) -> Markup {
    html! {
        form.inline method="post" action={ "/systems/" (name) "/jobs" } {
            input type="hidden" name="csrf" value=(csrf);
            input type="hidden" name="kind" value=(kind);
            @if let Some(m) = machine { input type="hidden" name="machine" value=(m); }
            button.btn type="submit" { (label) }
        }
    }
}

/// What the Status page shows: the update source, the machines, the recent jobs.
pub struct StatusView {
    pub updates: Option<String>,
    /// a deploy can run: an update source, machines, and the daemon's release keys
    pub deploys: bool,
    pub machines: Vec<MachineView>,
    pub recent: Vec<golconda_core::jobs::Job>,
}

/// One machine on the Status page: what it says, or why it said nothing.
pub struct MachineView {
    pub machine: golconda_core::machine::Machine,
    pub status: Result<golconda_core::machine::Status, String>,
}

/// A system's machines: version, slots, a newer version at the source, and the jobs an
/// operator can start (`csrf`: none for someone who may only read).
pub fn status(
    app: &App,
    who: &Identity,
    name: &str,
    sys: &System,
    view: &StatusView,
    csrf: Option<&str>,
) -> Markup {
    let (updates, machines, recent) = (view.updates.as_deref(), &view.machines, &view.recent);
    let main = html! {
        h2 { "Status" }
        p.m {
            "update source: "
            @if let Some(u) = updates { (u) } @else { "none (machines.toml)" }
            @if let (Some(c), true) = (csrf, view.deploys) { " " (job_form(name, c, "deploy", None, "Deploy")) }
        }
        @if machines.is_empty() {
            p { "No machines: list them in machines.toml beside the document." }
        } @else {
            table {
                tr { th { "machine" } th { "runs" } th { "slots" } th { "at the source" } @if csrf.is_some() { th {} } }
                @for m in machines {
                    tr {
                        td { (m.machine.name) br; small.m { (m.machine.ssh) } }
                        @match &m.status {
                            Err(e) => { td.m colspan="3" { span.pill.p-red { "unreachable" } " " (e) } }
                            Ok(st) => {
                                td.m { (st.version.as_deref().unwrap_or("?")) br; small { (st.hostname) } }
                                td.m {
                                    @for e in st.entries.iter().filter(|e| e.is_image()) {
                                        div {
                                            (e.version.as_deref().unwrap_or(""))
                                            @if e.selected { " " span.pill.p-sky { "booted" } }
                                            @if e.default && !e.selected { " " span.pill.p-amber { "next boot" } }
                                            @if let Some(t) = e.tries_left { " " span.pill.p-amber { (t) " tries left" } }
                                        }
                                    }
                                }
                                td.m {
                                    @match &st.available {
                                        Ok(Some(v)) => { span.pill.p-green { (v) } }
                                        Ok(None) => { "nothing newer" }
                                        Err(e) => { span.pill.p-amber { "could not check" } " " small { (e) } }
                                    }
                                }
                            }
                        }
                        @if let Some(c) = csrf {
                            td {
                                (job_form(name, c, "update", Some(&m.machine.name), "Update"))
                                (job_form(name, c, "reboot", Some(&m.machine.name), "Reboot"))
                                (job_form(name, c, "rollback", Some(&m.machine.name), "Roll back"))
                            }
                        }
                    }
                }
            }
        }
        @if !recent.is_empty() {
            h3 { "Recent jobs" }
            (job_table(recent))
        }
    };
    layout(
        app,
        who,
        Some((name, sys)),
        Some(Tab::Status),
        "Status",
        &main,
    )
}

fn state_class(state: State) -> &'static str {
    match state {
        State::Ok => "pill p-green",
        State::Queued | State::Running => "pill p-sky",
        State::Interrupted => "pill p-amber",
        State::Failed => "pill p-red",
    }
}

fn job_table(jobs: &[golconda_core::jobs::Job]) -> Markup {
    html! {
        table {
            tr { th { "job" } th { "kind" } th { "system" } th { "machine" } th { "by" } th { "created" } th { "state" } th { "summary" } }
            @for j in jobs {
                tr {
                    td.m { a href={ "/jobs/" (j.id) } { (j.id) } }
                    td.m { (j.kind) }
                    td.m { (j.system) }
                    td.m { (j.machine.as_deref().unwrap_or("all")) }
                    td { (j.by.name) }
                    td.m { (j.created) }
                    td { span class=(state_class(j.state)) { (j.state.name()) } }
                    td { (j.summary.as_deref().unwrap_or("")) }
                }
            }
        }
    }
}

pub fn jobs(app: &App, who: &Identity, jobs: &[golconda_core::jobs::Job]) -> Markup {
    let main = html! {
        h2 { "Jobs" }
        @if jobs.is_empty() { p { "No jobs yet." } } @else { (job_table(jobs)) }
    };
    layout(app, who, None, None, "Jobs", &main)
}

/// One job and its output; while it has not ended, the page reloads itself every 3 seconds
/// (without a script).
pub fn job(
    app: &App,
    who: &Identity,
    j: &golconda_core::jobs::Job,
    lines: &[(i64, String, String)],
) -> Markup {
    let main = html! {
        @if !j.state.ended() { meta http-equiv="refresh" content="3"; }
        h2 { "Job " (j.id) ": " (j.kind) " " (j.machine.as_deref().unwrap_or(&j.system)) }
        p {
            span class=(state_class(j.state)) { (j.state.name()) }
            " · " a href={ "/systems/" (j.system) "/machines" } { (j.system) }
            " · by " (j.by.name) " · created " (j.created)
            @if let Some(e) = &j.ended { " · ended " (e) }
        }
        @if let Some(s) = &j.summary { p { (s) } }
        pre.log {
            @for (_, at, line) in lines { span.m { (at) } "  " (line) "\n" }
        }
    };
    layout(app, who, None, None, &format!("Job {}", j.id), &main)
}

/// The image's packages, from its SBOM: what the image takes itself first.
pub fn packages(app: &App, who: &Identity, name: &str, sys: &System, list: &[Package]) -> Markup {
    let roots = list.iter().filter(|p| p.root).count();
    let main = html! {
        h2 { "Packages" }
        p {
            (list.len()) " components, " (roots) " of them named by the image itself, the rest what they need. "
            a href={ "/systems/" (name) "/sbom.json" } { "The SBOM" } " (CycloneDX)."
        }
        table {
            tr { th { "package" } th { "version" } th { "origin" } th { "identifier" } }
            @for p in list.iter().filter(|p| p.root).chain(list.iter().filter(|p| !p.root)) {
                tr {
                    td {
                        (p.name)
                        @if p.root { " " span.pill.p-sky { "in the image" } }
                        @if !p.replaces.is_empty() { br; small { "replaces " (p.replaces.join(", ")) } }
                    }
                    td.m { (p.version) }
                    td { @if let Some(o) = &p.origin { span class=(if o == "golconda" || o == "repkgs" { "pill p-grey" } else { "pill p-amber" }) { (o) } } }
                    td.m {
                        @if let Some(u) = &p.purl { (u) }
                        @if let Some(c) = &p.cpe { br; small { (c) } }
                    }
                }
            }
        }
    };
    layout(
        app,
        who,
        Some((name, sys)),
        Some(Tab::Packages),
        "Packages",
        &main,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use golconda_core::diff::Side;
    use serde_json::json;
    use std::slice;

    fn app(read_only: bool, level: Level) -> App {
        App::new(vec![], Signin::Dev(who(level)), read_only)
    }

    fn who(level: Level) -> Identity {
        Identity {
            id: "dev:bob".into(),
            name: "bob".into(),
            level,
        }
    }

    fn sys() -> System {
        System {
            root: "/c".into(),
            document: "server.toml".into(),
            text: String::new(),
            config: json!({ "/system": { "version": { "explicit": true, "value": "20261105.1" } },
                            "/services/sshd": { "port": { "explicit": true, "value": 22 } } }),
            schema: json!({ "properties": { "/system": {}, "/services/sshd": {}, "/network": {}, "golconda": {} } }),
            module_docs: json!({ "/services/sshd": "OpenSSH <daemon>.\n\nMore.", "/network": null }),
        }
    }

    #[test]
    fn values_are_escaped() {
        let e = Explanation {
            module: "/m".into(),
            option: "x".into(),
            type_name: "string".into(),
            description: Some("<script>alert(1)</script>".into()),
            value: Some(json!("</dd><b>")),
            explicit: true,
            default: None,
            set_at: None,
            declared_at: None,
        };
        let page = module(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
            "/m",
            slice::from_ref(&e),
            Some(&e),
            None,
        )
        .into_string();
        assert!(!page.contains("<script>"), "{page}");
        assert!(page.contains("&lt;script&gt;"), "{page}");
        assert!(!page.contains("</dd><b>"), "{page}");
    }

    #[test]
    fn the_tree_greys_modules_the_system_does_not_include() {
        let t = tree("s", &sys(), Some("/services/sshd")).into_string();
        assert!(
            t.contains(r#"<div class="on"><a href="/systems/s/config/services/sshd">"#),
            "{t}"
        );
        assert!(t.contains(r#"<div class="ghost"><a href="/systems/s/config/network">/network</a><small>not included</small>"#), "{t}");
        // an included module has no class at all
        assert!(
            t.contains(r#"<div><a href="/systems/s/config/system">"#),
            "{t}"
        );
        assert!(!t.contains("class=\"\""), "{t}");
        // [golconda] is not a module
        assert!(!t.contains("golconda<"), "{t}");
    }

    #[test]
    fn read_only_shows_in_the_strip_and_a_read_only_daemon_says_so() {
        let p = config(
            &app(false, Level::ReadOnly),
            &who(Level::ReadOnly),
            "s",
            &sys(),
        )
        .into_string();
        assert!(
            p.contains(r#"<span class="pill p-amber">read-only</span>"#),
            "{p}"
        );
        assert!(p.contains("bob · read-only"), "{p}");
        assert!(!p.contains("This console is read-only"), "{p}");
        let p = config(
            &app(true, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
        )
        .into_string();
        assert!(p.contains("This console is read-only"), "{p}");
        let p = config(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
        )
        .into_string();
        assert!(!p.contains("read-only"), "{p}");
    }

    #[test]
    fn the_config_page_lists_modules_with_the_first_paragraph() {
        let p = config(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
        )
        .into_string();
        assert!(p.contains("OpenSSH &lt;daemon&gt;."), "{p}");
        assert!(!p.contains("More."), "{p}");
        assert!(p.contains("image 20261105.1"), "{p}");
    }

    #[test]
    fn no_inline_style_or_script() {
        // the content security policy allows the stylesheet and nothing inline
        let a = app(false, Level::Operator);
        let e = sys().explain("/services/sshd", &["port"]).ok();
        for page in [
            config(&a, &who(Level::Operator), "s", &sys()).into_string(),
            module(
                &a,
                &who(Level::Operator),
                "s",
                &sys(),
                "/services/sshd",
                &[],
                e.as_ref(),
                None,
            )
            .into_string(),
            changes(&a, &who(Level::Operator), "s", &sys(), &[], None, None).into_string(),
            index(&a, &who(Level::Operator), &[("s".into(), "x".into())]).into_string(),
            problem(StatusCode::NOT_FOUND, "x").into_string(),
        ] {
            assert!(
                !page.contains("style=") && !page.contains("<script"),
                "{page}"
            );
        }
    }

    #[test]
    fn a_module_page_puts_the_rest_of_its_doc_in_details() {
        let p = module(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
            "/services/sshd",
            &[],
            None,
            None,
        )
        .into_string();
        assert!(
            p.contains("<div class=\"doc md\"><p>OpenSSH &lt;daemon&gt;.</p>\n</div><details class=\"doc\">"),
            "{p}"
        );
        assert!(
            p.contains("<div class=\"doc md\"><p>More.</p>\n</div></details>"),
            "{p}"
        );
    }

    #[test]
    fn markdown_is_rendered_and_nothing_unsafe_gets_through() {
        let m = |t: &str| markdown(t, false).into_string();
        assert_eq!(m("a `b` *c*"), "<p>a <code>b</code> <em>c</em></p>\n");
        assert_eq!(
            m("x\n\n- y\n- z"),
            "<p>x</p>\n<ul>\n<li>y</li>\n<li>z</li>\n</ul>\n"
        );
        // raw HTML is text
        assert_eq!(
            m("<script>alert(1)</script>"),
            "&lt;script&gt;alert(1)&lt;/script&gt;"
        );
        assert_eq!(
            m("a <b onclick=x>b</b>"),
            "<p>a &lt;b onclick=x&gt;b&lt;/b&gt;</p>\n"
        );
        // only http(s) links are links; images are left out
        assert_eq!(m("[x](javascript:alert(1))"), "<p>x</p>\n");
        assert_eq!(m("[x](docs/a.md)"), "<p>x</p>\n");
        assert_eq!(
            m("[x](https://systemd.io/)"),
            "<p><a href=\"https://systemd.io/\">x</a></p>\n"
        );
        assert_eq!(m("![alt](https://example.com/t.png)"), "<p>alt</p>\n");
        // tables, as module docs write them
        let t = m("| function | returns |\n| --- | --- |\n| `render var` | a fragment |\n");
        assert!(t.starts_with("<table><thead><tr><th>function</th>"), "{t}");
        assert!(
            t.contains("<td><code>render var</code></td><td>a fragment</td>"),
            "{t}"
        );
        // inline: no paragraph around it
        assert_eq!(markdown("a `b`", true).into_string(), "a <code>b</code>");
    }

    #[test]
    fn a_doc_splits_after_its_first_paragraph() {
        assert_eq!(split_doc("a\nb\n\nc\n\nd"), ("a\nb", "c\n\nd"));
        assert_eq!(split_doc("a"), ("a", ""));
    }

    #[test]
    fn summaries() {
        assert_eq!(summary(&json!(22)), "22");
        assert_eq!(summary(&json!(["a".repeat(50)])), "[1 item]");
        assert_eq!(summary(&json!(["a".repeat(40), "b"])), "[2 items]");
        assert_eq!(summary(&json!({ "k": "v".repeat(50) })), "{1 key}");
        assert_eq!(summary(&json!("x".repeat(50))).chars().count(), 40);
    }

    #[test]
    fn changes_show_both_sides_and_mark_defaults() {
        let c = vec![Change {
            module: "/factory".into(),
            path: vec!["timezone".into()],
            before: Side {
                value: Some(json!("UTC")),
                explicit: false,
            },
            after: Side {
                value: Some(json!("Europe/Berlin")),
                explicit: true,
            },
        }];
        let p = changes(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
            &c,
            None,
            None,
        )
        .into_string();
        assert!(p.contains(r#"<span class="hdr">/factory</span>"#), "{p}");
        assert!(
            p.contains(r#"<span class="del">- timezone = &quot;UTC&quot;  (default)</span>"#),
            "{p}"
        );
        assert!(
            p.contains(r#"<span class="add">+ timezone = &quot;Europe/Berlin&quot;</span>"#),
            "{p}"
        );
    }

    fn edit_view(ops: Vec<Op>) -> EditView {
        EditView {
            revision: 7,
            csrf: "tok".into(),
            candidate: json!({ "/services/sshd": { "port": 2222 } }),
            ops,
            draft: None,
        }
    }

    fn op_port() -> Op {
        Op {
            rev: 7,
            base: 6,
            module: "/services/sshd".into(),
            path: vec!["port".into()],
            edit: golconda_core::candidate::Edit::Set("2222".into()),
            by: golconda_core::candidate::Operator {
                id: "a".into(),
                name: "Alice".into(),
            },
            via: "web".into(),
            at: "t".into(),
            state: golconda_core::candidate::State::Open,
            commit: None,
        }
    }

    fn sshd() -> System {
        let mut s = sys();
        s.schema["properties"]["/services/sshd"]["properties"] = json!({
            "port": { "type": "integer", "minimum": 1, "maximum": 65535 },
            "flag": { "type": "boolean" },
            "keys": { "type": "array", "items": { "type": "string" } },
            "mode": { "enum": ["strict", "default"] },
            "name": { "type": "string" },
            "map": { "type": "object" },
        });
        s
    }

    fn page(e: &Explanation, edit: Option<&EditView>) -> String {
        module(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sshd(),
            "/services/sshd",
            slice::from_ref(e),
            Some(e),
            edit,
        )
        .into_string()
    }

    fn port() -> Explanation {
        sshd().explain("/services/sshd", &["port"]).unwrap()
    }

    #[test]
    fn the_form_carries_the_token_the_base_and_a_typed_control() {
        let p = page(&port(), Some(&edit_view(vec![op_port()])));
        for part in [
            r#"<form class="field" method="post" action="/systems/s/ops">"#,
            r#"<input type="hidden" name="csrf" value="tok">"#,
            r#"<input type="hidden" name="base" value="7">"#,
            r#"<input type="hidden" name="return" value="/systems/s/config/services/sshd?option=port">"#,
            // the candidate's value, a number within the schema's bounds
            r#"<input type="number" name="value" required min="1" max="65535" value="2222">"#,
            // set in the candidate: it can be reset
            "Reset to default",
            // the row is amber, with the committed value
            r#"<span class="v chg">2222 <span class="was">(was 22)</span></span>"#,
            // and the detail names the candidate's value beside the committed one
            r#"<dt>value</dt><dd>22</dd><dt>candidate</dt><dd class="chg">2222</dd>"#,
        ] {
            assert!(p.contains(part), "{part} in {p}");
        }
    }

    #[test]
    fn each_type_has_its_control() {
        let ev = edit_view(vec![]);
        let control_for = |opt: &str| {
            page(
                &sshd().explain("/services/sshd", &[opt]).unwrap(),
                Some(&ev),
            )
        };
        assert!(control_for("flag").contains(r#"<input type="radio" name="value" value="true">"#));
        assert!(control_for("keys").contains(
            r#"<input type="hidden" name="kind" value="lines"><textarea name="value" rows="4">"#
        ));
        assert!(
            control_for("mode")
                .contains(r#"<select name="value"><option value="strict">strict</option>"#)
        );
        assert!(control_for("name").contains(
            r#"<input type="hidden" name="kind" value="string"><input type="text" name="value">"#
        ));
        assert!(control_for("map").contains(
            r#"<input type="hidden" name="kind" value="toml"><textarea name="value" rows="4">"#
        ));
        // not set in the candidate: nothing to reset
        assert!(!control_for("name").contains("Reset to default"));
    }

    #[test]
    fn without_write_access_there_is_no_form() {
        let p = page(&port(), None);
        assert!(!p.contains("<form"), "{p}");
        assert!(!p.contains("chg"), "{p}");
    }

    #[test]
    fn a_draft_comes_back_into_the_form() {
        let mut ev = edit_view(vec![]);
        ev.draft = Some("2200".into());
        assert!(page(&port(), Some(&ev)).contains(r#"value="2200">"#));
    }

    #[test]
    fn the_conflict_page_offers_three_ways_on() {
        let form = json!({ "csrf": "tok", "module": "/services/sshd", "option": "port", "op": "set",
                           "value": "2200", "return": "/systems/s/config/services/sshd?option=port", "base": "6" });
        let p = conflict(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &form,
            &json!({ "target": "/services/sshd port", "value": 2200 }),
            &[op_port()],
            7,
            "/systems/s/config/services/sshd?option=port",
        )
        .into_string();
        for part in [
            "<td class=\"m\">set /services/sshd port 2222</td><td>Alice</td>",
            r#"<a class="btn" href="/systems/s/config/services/sshd?option=port">Keep theirs</a>"#,
            r#"<input type="hidden" name="base" value="7"><button class="btn pri" type="submit">Apply mine on top</button>"#,
            r#"<input type="hidden" name="value" value="2200">"#,
            r#"href="/systems/s/config/services/sshd?option=port&amp;draft=2200">Edit again</a>"#,
        ] {
            assert!(p.contains(part), "{part} in {p}");
        }
    }

    #[test]
    fn the_candidates_changes_with_commit_and_discard_for_an_operator() {
        let ops = vec![op_port()];
        let ev = edit_view(ops.clone());
        let p = changes(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
            &[],
            Some(&ops),
            Some(&ev),
        )
        .into_string();
        for part in [
            "<td class=\"m\">7</td><td class=\"m\">set /services/sshd port 2222</td><td>Alice</td>",
            r#"<form class="field" method="post" action="/systems/s/commit"><input type="hidden" name="csrf" value="tok">"#,
            r#"<textarea name="message" rows="3" required></textarea>"#,
            r#"<form method="post" action="/systems/s/discard">"#,
        ] {
            assert!(p.contains(part), "{part} in {p}");
        }
        // someone who may only read sees the operations, and no form
        let p = changes(
            &app(false, Level::ReadOnly),
            &who(Level::ReadOnly),
            "s",
            &sys(),
            &[],
            Some(&ops),
            None,
        )
        .into_string();
        assert!(
            p.contains("set /services/sshd port 2222") && !p.contains("<form"),
            "{p}"
        );
        // an empty candidate says so
        let p = changes(
            &app(false, Level::Operator),
            &who(Level::Operator),
            "s",
            &sys(),
            &[],
            Some(&[]),
            Some(&ev),
        )
        .into_string();
        assert!(
            p.contains("No changes in the candidate.") && !p.contains("/commit"),
            "{p}"
        );
    }
}
