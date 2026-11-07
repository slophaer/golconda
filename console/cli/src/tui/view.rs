//! Drawing the model: the strip at the top, the screen, the last message and the keys at the
//! bottom. The panes are the web pages': modules, options, detail.

use super::model::{Ask, Mode, Model, Pane, SCREENS, Screen};
use golconda_core::document::toml_text;
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use serde_json::Value;

const SKY: Color = Color::Blue;
const AMBER: Color = Color::Yellow;
const RED: Color = Color::Red;
const GREY: Color = Color::DarkGray;

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

fn shown(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        v => toml_text(v),
    }
}

pub fn draw(f: &mut Frame, m: &Model) {
    let [strip, body, message, keys] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(f.area());
    f.render_widget(Paragraph::new(strip_line(m)), strip);
    match m.screen {
        Screen::Status => status(f, m, body),
        Screen::Config => config(f, m, body),
        Screen::Packages => packages(f, m, body),
        Screen::Changes => changes(f, m, body),
        Screen::Jobs => jobs(f, m, body),
    }
    if let Some((bad, text)) = &m.message {
        let style = Style::default().fg(if *bad { RED } else { SKY });
        f.render_widget(
            Paragraph::new(Span::styled(format!(" {text}"), style)),
            message,
        );
    }
    f.render_widget(
        Paragraph::new(Span::styled(legend(m), Style::default().fg(GREY))),
        keys,
    );
    prompt(f, m, body);
}

fn strip_line(m: &Model) -> Line<'static> {
    let mut spans = vec![
        Span::styled(" golconda ", Style::default().add_modifier(Modifier::BOLD)),
        Span::raw(format!(" {} ", m.system)),
    ];
    if let Some(v) = &m.version {
        spans.push(Span::styled(
            format!(" image {v} "),
            Style::default().fg(GREY),
        ));
    }
    let n = m.ops.len();
    spans.push(Span::styled(
        format!(" candidate: {n} change{} ", if n == 1 { "" } else { "s" }),
        Style::default().fg(if n > 0 { AMBER } else { GREY }),
    ));
    if !m.lock.is_null() {
        spans.push(Span::styled(
            format!(
                " locked by {} until {} ",
                s(&m.lock["by"]["name"]),
                s(&m.lock["until"])
            ),
            Style::default().fg(AMBER),
        ));
    }
    for (i, (screen, name)) in SCREENS.iter().enumerate() {
        let style = if *screen == m.screen {
            Style::default().fg(SKY).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(GREY)
        };
        spans.push(Span::styled(format!(" [{}]{name}", i + 1), style));
    }
    Line::from(spans)
}

fn legend(m: &Model) -> String {
    let keys = match (&m.mode, m.screen) {
        (Mode::Edit { .. }, _) => "Enter saves to the candidate   Esc cancels   Ctrl-U clears",
        (Mode::Message { .. }, _) => "Enter commits and pushes   Esc cancels",
        (Mode::Reason { .. }, _) => "Enter breaks the lock   Esc cancels",
        (Mode::Confirm(_), _) => "y yes   any other key: no",
        (Mode::Normal, Screen::Status) => "u update  b reboot  R roll back  D deploy  j/k move",
        (Mode::Normal, Screen::Config) => "Tab pane  j/k move  e edit  D reset to default",
        (Mode::Normal, Screen::Packages) => "j/k move",
        (Mode::Normal, Screen::Changes) => "c commit  x discard  B break the lock",
        (Mode::Normal, Screen::Jobs) => "j/k job",
    };
    format!(" {keys}   l lock   r refresh   1-5 screens   q quit")
}

fn block(title: &str, on: bool) -> Block<'static> {
    let style = if on {
        Style::default().fg(SKY)
    } else {
        Style::default()
    };
    Block::default()
        .borders(Borders::TOP)
        .title(format!(" {title} "))
        .border_style(style)
}

fn pick(
    items: Vec<ListItem<'static>>,
    at: usize,
    title: &str,
    on: bool,
) -> (List<'static>, ListState) {
    let list = List::new(items)
        .block(block(title, on))
        .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
    let mut st = ListState::default();
    st.select(Some(at));
    (list, st)
}

fn status(f: &mut Frame, m: &Model, area: Rect) {
    let items: Vec<ListItem> = m
        .machines
        .iter()
        .map(|x| {
            if let Some(e) = x["error"].as_str() {
                return ListItem::new(Line::from(vec![
                    Span::raw(format!(" {:<10} ", s(&x["name"]))),
                    Span::styled(format!("unreachable: {e}"), Style::default().fg(RED)),
                ]));
            }
            let st = &x["status"];
            let slots: Vec<String> = st["entries"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|e| e["version"].is_string())
                .map(|e| {
                    let mark = if e["selected"] == true {
                        "●"
                    } else if e["default"] == true {
                        "→"
                    } else {
                        "○"
                    };
                    format!("{mark} {}", s(&e["version"]))
                })
                .collect();
            let source = match (st["available"].as_str(), st["checkError"].as_str()) {
                (Some(a), _) => Span::styled(
                    format!("{a} at the source"),
                    Style::default().fg(Color::Green),
                ),
                (None, Some(_)) => {
                    Span::styled("could not check".to_string(), Style::default().fg(AMBER))
                }
                _ => Span::styled("nothing newer".to_string(), Style::default().fg(GREY)),
            };
            ListItem::new(Line::from(vec![
                Span::raw(format!(" {:<10} {:<12} ", s(&x["name"]), s(&st["version"]))),
                Span::raw(format!("{:<28} ", slots.join("  "))),
                source,
            ]))
        })
        .collect();
    let (list, mut st) = pick(
        items,
        m.machine_at,
        "machines  (● booted  → next boot)",
        true,
    );
    f.render_stateful_widget(list, area, &mut st);
}

fn config(f: &mut Frame, m: &Model, area: Rect) {
    let [mods, opts, detail] = Layout::horizontal([
        Constraint::Percentage(25),
        Constraint::Percentage(40),
        Constraint::Percentage(35),
    ])
    .areas(area);
    let items: Vec<ListItem> = m
        .modules
        .iter()
        .map(|x| ListItem::new(format!(" {x}")))
        .collect();
    let (list, mut st) = pick(items, m.module_at, "modules", m.pane == Pane::Modules);
    f.render_stateful_widget(list, mods, &mut st);
    let changed: Vec<String> = m
        .ops
        .iter()
        .map(|o| {
            format!(
                "{} {}",
                s(&o["module"]),
                o["path"].as_array().map_or(String::new(), |p| {
                    p.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(".")
                })
            )
        })
        .collect();
    let items: Vec<ListItem> = m
        .options
        .iter()
        .map(|o| {
            let in_candidate = changed
                .iter()
                .any(|c| *c == format!("{} {}", s(&o["module"]), s(&o["option"])));
            let style = if in_candidate {
                Style::default().fg(AMBER)
            } else if o["explicit"] == true {
                Style::default().fg(SKY)
            } else {
                Style::default().fg(GREY)
            };
            ListItem::new(Line::from(vec![
                Span::raw(format!(" {:<22} ", s(&o["option"]))),
                Span::styled(shown(&o["value"]), style),
            ]))
        })
        .collect();
    let title = m.modules.get(m.module_at).map_or("options", String::as_str);
    let (list, mut st) = pick(items, m.option_at, title, m.pane == Pane::Options);
    f.render_stateful_widget(list, opts, &mut st);
    let text = match m.options.get(m.option_at) {
        None => vec![Line::raw(" no options")],
        Some(o) => {
            let row = |k: &str, v: String| {
                Line::from(vec![
                    Span::styled(format!(" {k:<9} "), Style::default().fg(GREY)),
                    Span::raw(v),
                ])
            };
            let mut t = vec![
                Line::raw(format!(" {}", s(&o["description"]))),
                Line::raw(""),
                row("type", s(&o["type"]).to_string()),
                row("value", shown(&o["value"])),
                row("default", shown(&o["default"])),
                row(
                    "set",
                    if o["explicit"] == true {
                        "in the document".into()
                    } else {
                        "default".into()
                    },
                ),
            ];
            if let Some(d) = o["declaredIn"]["file"].as_str() {
                t.push(row("declared", format!("{d}:{}", o["declaredIn"]["line"])));
            }
            t
        }
    };
    let title = m
        .options
        .get(m.option_at)
        .map_or(String::new(), |o| s(&o["option"]).to_string());
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .block(block(&title, false)),
        detail,
    );
}

/// "-> 3.0.2 " for a package with a newer upstream version; nothing otherwise.
fn newer(upstream: &Value) -> String {
    match (upstream["outdated"].as_bool(), upstream["newest"].as_str()) {
        (Some(true), Some(v)) => format!("-> {v} "),
        _ => String::new(),
    }
}

/// The ids of a package's advisories, a space after them; nothing when there are none.
fn vulnerabilities(advisories: &Value) -> String {
    let ids: Vec<&str> = advisories
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|a| a["id"].as_str())
        .collect();
    if ids.is_empty() {
        String::new()
    } else {
        format!("{} ", ids.join(" "))
    }
}

fn packages(f: &mut Frame, m: &Model, area: Rect) {
    let items: Vec<ListItem> = m
        .packages
        .iter()
        .map(|p| {
            ListItem::new(Line::from(vec![
                Span::raw(format!(" {:<20} {:<14} ", s(&p["name"]), s(&p["version"]))),
                Span::styled(
                    format!("{:<10} ", s(&p["origin"])),
                    Style::default().fg(GREY),
                ),
                Span::styled(
                    if p["root"] == true {
                        "in the image  "
                    } else {
                        "              "
                    },
                    Style::default().fg(SKY),
                ),
                Span::styled(newer(&p["upstream"]), Style::default().fg(AMBER)),
                Span::styled(vulnerabilities(&p["advisories"]), Style::default().fg(RED)),
                Span::styled(
                    if p["osvCovered"] == false && p["purl"].is_string() {
                        "not in OSV "
                    } else {
                        ""
                    },
                    Style::default().fg(GREY),
                ),
                Span::raw(s(&p["purl"]).to_string()),
            ]))
        })
        .collect();
    let note = [
        (m.packages_error.as_ref(), "vulnerabilities"),
        (m.upstream_error.as_ref(), "upstream versions"),
    ]
    .iter()
    .filter_map(|(e, what)| e.map(|e| format!(" · could not check {what}: {e}")))
    .collect::<String>();
    let (list, mut st) = pick(
        items,
        m.package_at,
        &format!("packages ({}){note}", m.packages.len()),
        true,
    );
    f.render_stateful_widget(list, area, &mut st);
}

fn changes(f: &mut Frame, m: &Model, area: Rect) {
    let [ops, diff] =
        Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).areas(area);
    let items: Vec<ListItem> = m
        .ops
        .iter()
        .map(|o| {
            let path: Vec<&str> = o["path"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            let what = if o["op"] == "set" {
                format!(
                    "set {} {} {}",
                    s(&o["module"]),
                    path.join("."),
                    s(&o["value"])
                )
            } else {
                format!("delete {} {}", s(&o["module"]), path.join("."))
            };
            ListItem::new(format!(" {:>4}  {what}  {}", o["rev"], s(&o["by"]["name"])))
        })
        .collect();
    let title = format!("candidate, revision {}", m.revision);
    f.render_widget(List::new(items).block(block(&title, true)), ops);
    let mut lines = Vec::new();
    for c in &m.changes {
        let path: Vec<&str> = c["path"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        lines.push(Line::styled(
            format!(" {}", s(&c["module"])),
            Style::default().fg(GREY),
        ));
        if !c["before"]["value"].is_null() {
            lines.push(Line::styled(
                format!(" - {} = {}", path.join("."), shown(&c["before"]["value"])),
                Style::default().fg(RED),
            ));
        }
        if !c["after"]["value"].is_null() {
            lines.push(Line::styled(
                format!(" + {} = {}", path.join("."), shown(&c["after"]["value"])),
                Style::default().fg(Color::Green),
            ));
        }
    }
    f.render_widget(
        Paragraph::new(lines).block(block("what changes", false)),
        diff,
    );
}

fn jobs(f: &mut Frame, m: &Model, area: Rect) {
    let [list_area, log] =
        Layout::horizontal([Constraint::Percentage(45), Constraint::Percentage(55)]).areas(area);
    let items: Vec<ListItem> = m
        .jobs
        .iter()
        .map(|j| {
            let color = match s(&j["state"]) {
                "ok" => Color::Green,
                "failed" => RED,
                "interrupted" => AMBER,
                _ => SKY,
            };
            ListItem::new(Line::from(vec![
                Span::raw(format!(
                    " {:>4} {:<9} {:<8} ",
                    j["id"],
                    s(&j["kind"]),
                    j["machine"].as_str().unwrap_or("all")
                )),
                Span::styled(s(&j["state"]).to_string(), Style::default().fg(color)),
            ]))
        })
        .collect();
    let (list, mut st) = pick(items, m.job_at, "jobs", true);
    f.render_stateful_widget(list, list_area, &mut st);
    let lines: Vec<Line> = m
        .job_lines
        .iter()
        .map(|l| Line::raw(format!(" {l}")))
        .collect();
    let skip = lines
        .len()
        .saturating_sub(usize::from(log.height.saturating_sub(1)));
    f.render_widget(
        Paragraph::new(lines[skip..].to_vec()).block(block("output", false)),
        log,
    );
}

/// The editor or the question, as a box over the screen's lower right.
fn prompt(f: &mut Frame, m: &Model, body: Rect) {
    let (title, text) = match &m.mode {
        Mode::Normal => return,
        Mode::Edit { option, buffer, .. } => (format!(" edit {option} "), buffer.clone()),
        Mode::Message { buffer } => (" commit message ".to_string(), buffer.clone()),
        Mode::Reason { buffer } => (" why break the lock ".to_string(), buffer.clone()),
        Mode::Confirm(ask) => (
            " sure? ".to_string(),
            match ask {
                Ask::Job {
                    kind,
                    machine: Some(mach),
                } => format!("{kind} {mach}? y/n"),
                Ask::Job {
                    kind,
                    machine: None,
                } => format!("{kind} {}? y/n", m.system),
                Ask::Reset { module, option } => {
                    format!("reset {module} {option} to its default? y/n")
                }
                Ask::Discard => "discard the candidate? y/n".to_string(),
            },
        ),
    };
    let w = body.width.min(48);
    let area = Rect {
        x: body.x + body.width - w,
        y: body.y + body.height.saturating_sub(4),
        width: w,
        height: 3.min(body.height),
    };
    f.render_widget(Clear, area);
    f.render_widget(
        Paragraph::new(format!("{text}▏"))
            .block(Block::default().borders(Borders::ALL).title(title)),
        area,
    );
}
