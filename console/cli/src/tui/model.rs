//! The TUI's state and what each key does, without a terminal: the tests drive it with a
//! stand-in daemon and read what it sends.

use super::source::Source;
use golconda_core::document::parse_value;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::mem;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Status,
    Config,
    Packages,
    Changes,
    Jobs,
}

pub const SCREENS: [(Screen, &str); 5] = [
    (Screen::Status, "status"),
    (Screen::Config, "config"),
    (Screen::Packages, "pkgs"),
    (Screen::Changes, "changes"),
    (Screen::Jobs, "jobs"),
];

/// What a y/n question would do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ask {
    Job {
        kind: String,
        machine: Option<String>,
    },
    Reset {
        module: String,
        option: String,
    },
    Discard,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Normal,
    /// a value being typed for `module` `option`
    Edit {
        module: String,
        option: String,
        buffer: String,
    },
    /// a commit message being typed
    Message {
        buffer: String,
    },
    /// a reason to break someone's lock
    Reason {
        buffer: String,
    },
    Confirm(Ask),
}

/// The configuration screen's panes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pane {
    Modules,
    Options,
}

pub struct Model {
    pub system: String,
    pub screen: Screen,
    pub mode: Mode,
    /// the last answer: (is it an error, the text)
    pub message: Option<(bool, String)>,
    pub quit: bool,
    /// who this is (`/auth/me`)
    pub me: Value,
    // the strip
    pub version: Option<String>,
    pub revision: u64,
    pub ops: Vec<Value>,
    pub lock: Value,
    // configuration
    pub modules: Vec<String>,
    pub module_at: usize,
    pub options: Vec<Value>,
    pub option_at: usize,
    pub pane: Pane,
    // the rest
    pub machines: Vec<Value>,
    pub machine_at: usize,
    pub packages: Vec<Value>,
    /// why OSV could not be asked about the packages, if so
    pub packages_error: Option<String>,
    pub package_at: usize,
    pub changes: Vec<Value>,
    pub jobs: Vec<Value>,
    pub job_at: usize,
    pub job_lines: Vec<String>,
}

fn list(v: &Value) -> Vec<Value> {
    v.as_array().cloned().unwrap_or_default()
}

fn step(at: &mut usize, len: usize, down: bool) {
    if len == 0 {
        *at = 0;
    } else if down {
        *at = (*at + 1).min(len - 1);
    } else {
        *at = at.saturating_sub(1);
    }
}

impl Model {
    pub fn new(system: &str) -> Model {
        Model {
            system: system.into(),
            screen: Screen::Status,
            mode: Mode::Normal,
            message: None,
            quit: false,
            me: Value::Null,
            version: None,
            revision: 0,
            ops: Vec::new(),
            lock: Value::Null,
            modules: Vec::new(),
            module_at: 0,
            options: Vec::new(),
            option_at: 0,
            pane: Pane::Modules,
            machines: Vec::new(),
            machine_at: 0,
            packages: Vec::new(),
            packages_error: None,
            package_at: 0,
            changes: Vec::new(),
            jobs: Vec::new(),
            job_at: 0,
            job_lines: Vec::new(),
        }
    }

    fn path(&self, rest: &str) -> String {
        format!("/systems/{}/{rest}", self.system)
    }

    fn fail(&mut self, e: impl Into<String>) {
        self.message = Some((true, e.into()));
    }

    fn say(&mut self, m: impl Into<String>) {
        self.message = Some((false, m.into()));
    }

    /// The strip and the current screen, from the daemon.
    pub fn refresh(&mut self, src: &dyn Source) {
        if self.me.is_null()
            && let Ok(me) = src.get("/auth/me")
        {
            self.me = me;
        }
        match src.get(&self.path("candidate")) {
            Ok(c) => {
                self.revision = c["revision"].as_u64().unwrap_or(0);
                self.ops = list(&c["ops"]);
                self.lock = c["lock"].clone();
            }
            Err(e) => return self.fail(e),
        }
        let done = match self.screen {
            Screen::Status => src.get(&self.path("machines")).map(|v| {
                self.machines = list(&v["machines"]);
                step(&mut self.machine_at, self.machines.len(), false);
            }),
            Screen::Config => self.load_config(src),
            Screen::Packages => src.get(&self.path("packages")).map(|v| {
                self.packages = list(&v["packages"]);
                self.packages_error = v["advisories"]["error"].as_str().map(str::to_string);
            }),
            Screen::Changes => src
                .get(&self.path("changes"))
                .map(|v| self.changes = list(&v["changes"])),
            Screen::Jobs => self.load_jobs(src),
        };
        if let Err(e) = done {
            self.fail(e);
        }
    }

    fn load_config(&mut self, src: &dyn Source) -> Result<(), String> {
        let config = src.get(&self.path("config"))?;
        self.version = config["/system"]["version"]["value"]
            .as_str()
            .map(str::to_string);
        self.modules = config
            .as_object()
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default();
        self.modules.sort();
        self.module_at = self.module_at.min(self.modules.len().saturating_sub(1));
        self.load_options(src)
    }

    fn load_options(&mut self, src: &dyn Source) -> Result<(), String> {
        let Some(module) = self.modules.get(self.module_at) else {
            self.options.clear();
            return Ok(());
        };
        let m = src.get(&self.path(&format!("config{module}")))?;
        self.options = list(&m["options"]);
        self.option_at = self.option_at.min(self.options.len().saturating_sub(1));
        Ok(())
    }

    fn load_jobs(&mut self, src: &dyn Source) -> Result<(), String> {
        self.jobs = list(&src.get(&format!("/jobs?system={}", self.system))?);
        self.load_job(src)
    }

    fn load_job(&mut self, src: &dyn Source) -> Result<(), String> {
        let Some(id) = self.jobs.get(self.job_at).and_then(|j| j["id"].as_i64()) else {
            self.job_lines.clear();
            return Ok(());
        };
        let v = src.get(&format!("/jobs/{id}"))?;
        if let Some(j) = self.jobs.get_mut(self.job_at) {
            *j = v["job"].clone();
        }
        self.job_lines = list(&v["lines"])
            .iter()
            .map(|l| l["line"].as_str().unwrap_or("").to_string())
            .collect();
        Ok(())
    }

    /// A job still running: its output, again.
    pub fn tick(&mut self, src: &dyn Source) {
        let running = self
            .jobs
            .get(self.job_at)
            .is_some_and(|j| matches!(j["state"].as_str(), Some("queued" | "running")));
        if self.screen == Screen::Jobs
            && running
            && let Err(e) = self.load_job(src)
        {
            self.fail(e);
        }
    }

    pub fn key(&mut self, k: KeyEvent, src: &dyn Source) {
        match self.mode.clone() {
            Mode::Normal => self.normal(k, src),
            Mode::Confirm(ask) => {
                self.mode = Mode::Normal;
                if matches!(k.code, KeyCode::Char('y' | 'Y')) {
                    self.confirmed(ask, src);
                } else {
                    self.say("not done");
                }
            }
            Mode::Edit { .. } | Mode::Message { .. } | Mode::Reason { .. } => self.typing(k, src),
        }
    }

    fn typing(&mut self, k: KeyEvent, src: &dyn Source) {
        let (Mode::Edit { buffer, .. } | Mode::Message { buffer } | Mode::Reason { buffer }) =
            &mut self.mode
        else {
            return;
        };
        match k.code {
            KeyCode::Esc => self.mode = Mode::Normal,
            KeyCode::Backspace => {
                buffer.pop();
            }
            KeyCode::Char('u') if k.modifiers.contains(KeyModifiers::CONTROL) => buffer.clear(),
            KeyCode::Char(c) => buffer.push(c),
            KeyCode::Enter => {
                let mode = mem::replace(&mut self.mode, Mode::Normal);
                match mode {
                    Mode::Edit {
                        module,
                        option,
                        buffer,
                    } => self.set(src, &module, &option, &buffer),
                    Mode::Message { buffer } => self.commit(src, &buffer),
                    Mode::Reason { buffer } => self.break_lock(src, &buffer),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn normal(&mut self, k: KeyEvent, src: &dyn Source) {
        let screen = match k.code {
            KeyCode::Char('1') => Some(Screen::Status),
            KeyCode::Char('2') => Some(Screen::Config),
            KeyCode::Char('3') => Some(Screen::Packages),
            KeyCode::Char('4') => Some(Screen::Changes),
            KeyCode::Char('5') => Some(Screen::Jobs),
            _ => None,
        };
        if let Some(s) = screen {
            self.screen = s;
            self.message = None;
            return self.refresh(src);
        }
        let (down, up) = (
            matches!(k.code, KeyCode::Down | KeyCode::Char('j')),
            matches!(k.code, KeyCode::Up | KeyCode::Char('k')),
        );
        match (self.screen, k.code) {
            (_, KeyCode::Char('q')) => self.quit = true,
            (_, KeyCode::Char('r')) => self.refresh(src),
            (_, KeyCode::Char('l')) => self.toggle_lock(src),
            (Screen::Config, KeyCode::Tab | KeyCode::Right | KeyCode::Enter)
                if self.pane == Pane::Modules =>
            {
                self.pane = Pane::Options;
            }
            (Screen::Config, KeyCode::Tab | KeyCode::Left | KeyCode::Esc) => {
                self.pane = Pane::Modules;
            }
            (Screen::Config, _) if down || up => {
                if self.pane == Pane::Modules {
                    step(&mut self.module_at, self.modules.len(), down);
                    self.option_at = 0;
                    if let Err(e) = self.load_options(src) {
                        self.fail(e);
                    }
                } else {
                    step(&mut self.option_at, self.options.len(), down);
                }
            }
            (Screen::Config, KeyCode::Char('e')) => self.edit(),
            (Screen::Config, KeyCode::Char('D')) => {
                if let Some(o) = self.options.get(self.option_at) {
                    self.mode = Mode::Confirm(Ask::Reset {
                        module: o["module"].as_str().unwrap_or("").into(),
                        option: o["option"].as_str().unwrap_or("").into(),
                    });
                }
            }
            (Screen::Status, _) if down || up => {
                step(&mut self.machine_at, self.machines.len(), down);
            }
            (Screen::Status, KeyCode::Char(c @ ('u' | 'b' | 'R'))) => {
                let kind = match c {
                    'u' => "update",
                    'b' => "reboot",
                    _ => "rollback",
                };
                let machine = self
                    .machines
                    .get(self.machine_at)
                    .and_then(|m| m["name"].as_str());
                if let Some(m) = machine {
                    self.mode = Mode::Confirm(Ask::Job {
                        kind: kind.into(),
                        machine: Some(m.into()),
                    });
                }
            }
            (Screen::Status, KeyCode::Char('D')) => {
                self.mode = Mode::Confirm(Ask::Job {
                    kind: "deploy".into(),
                    machine: None,
                });
            }
            (Screen::Packages, _) if down || up => {
                step(&mut self.package_at, self.packages.len(), down);
            }
            (Screen::Changes, KeyCode::Char('c')) => {
                self.mode = Mode::Message {
                    buffer: String::new(),
                }
            }
            (Screen::Changes, KeyCode::Char('x')) => self.mode = Mode::Confirm(Ask::Discard),
            (Screen::Changes, KeyCode::Char('B')) => {
                self.mode = Mode::Reason {
                    buffer: String::new(),
                }
            }
            (Screen::Jobs, _) if down || up => {
                step(&mut self.job_at, self.jobs.len(), down);
                if let Err(e) = self.load_job(src) {
                    self.fail(e);
                }
            }
            _ => {}
        }
    }

    fn edit(&mut self) {
        let Some(o) = self.options.get(self.option_at) else {
            return;
        };
        let current = match &o["value"] {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            v => golconda_core::document::toml_text(v),
        };
        self.mode = Mode::Edit {
            module: o["module"].as_str().unwrap_or("").into(),
            option: o["option"].as_str().unwrap_or("").into(),
            buffer: current,
        };
    }

    /// What the daemon said to a write, as a message; the screen again after it.
    fn answer(
        &mut self,
        src: &dyn Source,
        done: Result<(u16, Value), String>,
        ok: impl FnOnce(&Value) -> String,
    ) {
        match done {
            Err(e) => self.fail(e),
            Ok((200, v)) => {
                self.say(ok(&v));
                self.refresh(src);
            }
            Ok((409, v)) => {
                let theirs: Vec<String> = list(&v["theirs"])
                    .iter()
                    .map(|o| {
                        format!(
                            "rev {} by {}",
                            o["rev"],
                            o["by"]["name"].as_str().unwrap_or("?")
                        )
                    })
                    .collect();
                self.fail(format!(
                    "conflict with {}: r to see it, then edit again",
                    theirs.join(", ")
                ));
            }
            Ok((422, v)) => {
                let p: Vec<String> = list(&v["problems"])
                    .iter()
                    .map(|p| {
                        format!(
                            "{} {}",
                            p["path"].as_str().unwrap_or(""),
                            p["message"].as_str().unwrap_or("")
                        )
                    })
                    .collect();
                self.fail(p.join("; "));
            }
            Ok((423, v)) => self.fail(format!(
                "{} holds the lock until {}",
                v["lock"]["by"]["name"].as_str().unwrap_or("someone"),
                v["lock"]["until"].as_str().unwrap_or("?")
            )),
            Ok((s, v)) => self.fail(format!(
                "{s}: {}",
                v["error"].as_str().unwrap_or("no answer")
            )),
        }
    }

    fn set(&mut self, src: &dyn Source, module: &str, option: &str, typed: &str) {
        // TOML, as the CLI takes it: text that is not TOML is a string
        let value = parse_value(typed).to_string().trim().to_string();
        let body = json!({ "base": self.revision, "module": module, "option": option, "op": "set", "value": value });
        let done = src.post(&self.path("ops"), &body);
        self.answer(src, done, |v| {
            format!("rev {}: set {module} {option} = {value}", v["rev"])
        });
    }

    fn commit(&mut self, src: &dyn Source, message: &str) {
        let done = src.post(&self.path("commit"), &json!({ "message": message }));
        self.answer(src, done, |v| {
            format!("committed {}", v["commit"].as_str().unwrap_or("?"))
        });
    }

    fn break_lock(&mut self, src: &dyn Source, reason: &str) {
        let done = src.post(&self.path("lock/break"), &json!({ "reason": reason }));
        self.answer(src, done, |v| {
            format!(
                "broke {}'s lock",
                v["broken"]["by"]["name"].as_str().unwrap_or("someone")
            )
        });
    }

    fn toggle_lock(&mut self, src: &dyn Source) {
        let mine = !self.lock.is_null() && self.lock["by"]["id"] == self.me["id"];
        if mine {
            let done = src.post(&self.path("unlock"), &json!({}));
            self.answer(src, done, |_| "unlocked".into());
        } else if self.lock.is_null() {
            let done = src.post(&self.path("lock"), &json!({ "minutes": 30 }));
            self.answer(src, done, |v| {
                format!(
                    "locked until {}",
                    v["lock"]["until"].as_str().unwrap_or("?")
                )
            });
        } else {
            self.fail(format!(
                "{} holds the lock: B on the changes screen breaks it, with a reason",
                self.lock["by"]["name"].as_str().unwrap_or("someone")
            ));
        }
    }

    fn confirmed(&mut self, ask: Ask, src: &dyn Source) {
        match ask {
            Ask::Job { kind, machine } => {
                let done = src.post(
                    &self.path("jobs"),
                    &json!({ "kind": kind, "machine": machine }),
                );
                let started = matches!(&done, Ok((200, _)));
                self.answer(src, done, |v| format!("job {} queued", v["job"]));
                if started {
                    self.screen = Screen::Jobs;
                    self.job_at = 0;
                    if let Err(e) = self.load_jobs(src) {
                        self.fail(e);
                    }
                }
            }
            Ask::Reset { module, option } => {
                let body = json!({ "base": self.revision, "module": module, "option": option, "op": "delete" });
                let done = src.post(&self.path("ops"), &body);
                self.answer(src, done, |v| {
                    format!("rev {}: reset {module} {option}", v["rev"])
                });
            }
            Ask::Discard => {
                let done = src.post(&self.path("discard"), &json!({}));
                self.answer(src, done, |_| "discarded".into());
            }
        }
    }
}
