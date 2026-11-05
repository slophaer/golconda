//! The pages, server-rendered (maud escapes every value). No script and no request to
//! another origin: a page is complete without either (design: ui-design.md §8).

use crate::app::App;
use axum::http::StatusCode;
use golconda_core::diff::Change;
use golconda_core::document::{path_name, toml_text};
use golconda_core::system::{Explanation, System};
use maud::{DOCTYPE, Markup, PreEscaped, html};
use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use serde_json::Value;

#[derive(PartialEq, Clone, Copy)]
enum Tab {
    Config,
    Changes,
}

/// The frame: the strip (system, image, who), the read-only banner, the rail.
fn layout(
    app: &App,
    system: Option<(&str, &System)>,
    tab: Option<Tab>,
    title: &str,
    main: Markup,
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
                        span.cr {
                            @if app.read_only || app.identity.level == crate::app::Level::ReadOnly {
                                span.pill.p-amber { "read-only" }
                            }
                            span.pill.p-sky { (app.identity.name) " · " (app.identity.level.name()) }
                        }
                    }
                    @if app.read_only {
                        div.banner.amber { "This console is read-only: it shows state and changes nothing." }
                    }
                    div.body {
                        nav.rail {
                            @if let Some((name, _)) = system {
                                a class=[(tab == Some(Tab::Config)).then_some("on")] href={ "/systems/" (name) "/config" } { "Configuration" }
                                a class=[(tab == Some(Tab::Changes)).then_some("on")] href={ "/systems/" (name) "/changes" } { "Changes" }
                            }
                        }
                        main.main { (main) }
                    }
                }
            }
        }
    }
}

pub fn index(app: &App, systems: &[(String, std::path::PathBuf)]) -> Markup {
    layout(
        app,
        None,
        None,
        "Systems",
        html! {
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
        },
    )
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

fn first_paragraph(doc: &str) -> &str {
    doc.split("\n\n").next().unwrap_or(doc)
}

/// Markdown (module docs, option descriptions) as HTML. Raw HTML in it is shown as text,
/// images are left out (they would load from elsewhere), and a link stays a link only to
/// http(s); any other link is its text. `inline`: no paragraph around a single line.
pub fn markdown(text: &str, inline: bool) -> Markup {
    // for each open link: whether it is kept
    let mut links = Vec::new();
    let events = Parser::new(text).filter_map(|e| match e {
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

pub fn config(app: &App, name: &str, sys: &System) -> Markup {
    let main = html! {
        div.three {
            (tree(name, sys, None))
            div {
                h2 { "Modules" }
                @for (m, doc) in sys.module_docs.as_object().into_iter().flatten() {
                    a.opt href={ "/systems/" (name) "/config" (m) } {
                        span.n { (m) }
                        span.v.def { @if sys.config.get(m.as_str()).is_none() { "not included" } }
                        @if let Some(d) = doc.as_str() { span.desc { (markdown(first_paragraph(d), true)) } }
                    }
                }
            }
            div.detail { p.empty { "Choose a module." } }
        }
    };
    layout(
        app,
        Some((name, sys)),
        Some(Tab::Config),
        "Configuration",
        main,
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
        .fold(0xcbf29ce484222325u64, |h, b| {
            (h ^ b as u64).wrapping_mul(0x100000001b3)
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

pub fn module(
    app: &App,
    name: &str,
    sys: &System,
    module: &str,
    options: &[Explanation],
    selected: Option<&Explanation>,
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
                    @let (first, rest) = d.split_once("\n\n").unwrap_or((d, ""));
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
                        @match &o.value {
                            Some(v) => span class={ "v " (if o.explicit { "set" } else { "def" }) } { (summary(v)) },
                            None => span.v.def { "none" },
                        }
                        @if let Some(d) = &o.description { span.desc { (markdown(d, true)) } }
                    }
                }
                div.legend { "default" " · " span.set { "set in " (sys.document.display()) } }
            }
            div.detail {
                @match selected {
                    Some(e) => (detail(e)),
                    None => p.empty { "Choose an option." },
                }
            }
        }
    };
    layout(app, Some((name, sys)), Some(Tab::Config), module, main)
}

fn detail(e: &Explanation) -> Markup {
    html! {
        h4 { (e.module) " " (e.option) }
        @if let Some(d) = &e.description { div.md { (markdown(d, false)) } }
        dl {
            dt { "type" } dd { (e.type_name) }
            dt { "value" } dd { (e.value.as_ref().map_or("none".into(), toml_text)) }
            @if let Some(d) = &e.default { dt { "default" } dd { (toml_text(d)) } }
            @if let Some((f, l)) = &e.declared_at { dt { "declared" } dd { (f) ":" (l) } }
            @if let Some((f, l)) = &e.set_at { dt { "in TOML" } dd { (f) ":" (l) } }
        }
    }
}

pub fn changes(app: &App, name: &str, sys: &System, changes: &[Change]) -> Markup {
    let main = html! {
        h2 { "Changes" }
        p.doc { (sys.document.display()) " in the working tree, against git's HEAD." }
        @if changes.is_empty() {
            p { "No changes against HEAD." }
        } @else {
            div.diff {
                @for (i, c) in changes.iter().enumerate() {
                    @if i == 0 || changes[i - 1].module != c.module { span.hdr { (c.module) } "\n" }
                    @let at = { let p: Vec<&str> = c.path.iter().map(String::as_str).collect(); if p.is_empty() { "(module)".to_string() } else { path_name("", &p).trim().to_string() } };
                    @if let Some(v) = &c.before.value {
                        span.del { "- " (at) " = " (toml_text(v)) @if !c.before.explicit { "  (default)" } } "\n"
                    }
                    @if let Some(v) = &c.after.value {
                        span.add { "+ " (at) " = " (toml_text(v)) @if !c.after.explicit { "  (default)" } } "\n"
                    }
                }
            }
        }
    };
    layout(app, Some((name, sys)), Some(Tab::Changes), "Changes", main)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::{Identity, Level};
    use serde_json::json;

    fn app(read_only: bool, level: Level) -> App {
        App::new(
            vec![],
            Identity {
                name: "bob".into(),
                level,
            },
            read_only,
        )
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
            "s",
            &sys(),
            "/m",
            std::slice::from_ref(&e),
            Some(&e),
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
        let p = config(&app(false, Level::ReadOnly), "s", &sys()).into_string();
        assert!(
            p.contains(r#"<span class="pill p-amber">read-only</span>"#),
            "{p}"
        );
        assert!(p.contains("bob · read-only"), "{p}");
        assert!(!p.contains("This console is read-only"), "{p}");
        let p = config(&app(true, Level::Operator), "s", &sys()).into_string();
        assert!(p.contains("This console is read-only"), "{p}");
        let p = config(&app(false, Level::Operator), "s", &sys()).into_string();
        assert!(!p.contains("read-only"), "{p}");
    }

    #[test]
    fn the_config_page_lists_modules_with_the_first_paragraph() {
        let p = config(&app(false, Level::Operator), "s", &sys()).into_string();
        assert!(p.contains("OpenSSH &lt;daemon&gt;."), "{p}");
        assert!(!p.contains("More."), "{p}");
        assert!(p.contains("image 20261105.1"), "{p}");
    }

    #[test]
    fn no_inline_style_or_script() {
        // the content security policy allows the stylesheet and nothing inline
        let a = app(false, Level::Operator);
        let e = sys().explain("/services/sshd", "port").ok();
        for page in [
            config(&a, "s", &sys()).into_string(),
            module(&a, "s", &sys(), "/services/sshd", &[], e.as_ref()).into_string(),
            changes(&a, "s", &sys(), &[]).into_string(),
            index(&a, &[("s".into(), "x".into())]).into_string(),
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
            "s",
            &sys(),
            "/services/sshd",
            &[],
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
        // inline: no paragraph around it
        assert_eq!(markdown("a `b`", true).into_string(), "a <code>b</code>");
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
        use golconda_core::diff::Side;
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
        let p = changes(&app(false, Level::Operator), "s", &sys(), &c).into_string();
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
}
