//! `golconda tui`: the daemon's screens in a terminal, a client of its JSON routes like the CLI.

mod model;
mod source;
mod view;

use model::Model;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use source::Daemon;
use std::io::{self, Stdout};
use std::time::{Duration, Instant};

/// The terminal back as it was, however the TUI ends.
struct Screen(Terminal<CrosstermBackend<Stdout>>);

impl Drop for Screen {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(self.0.backend_mut(), LeaveAlternateScreen);
        let _ = self.0.show_cursor();
    }
}

/// Runs the TUI against the daemon at `url`, system `name`, until q.
pub fn run(url: &str, name: &str) -> Result<String, String> {
    let src = Daemon::new(url)?;
    let mut m = Model::new(name);
    m.refresh(&src);
    enable_raw_mode().map_err(|e| e.to_string())?;
    let mut out = io::stdout();
    execute!(out, EnterAlternateScreen).map_err(|e| e.to_string())?;
    let mut screen = Screen(Terminal::new(CrosstermBackend::new(out)).map_err(|e| e.to_string())?);
    let (mut ticked, mut refreshed) = (Instant::now(), Instant::now());
    while !m.quit {
        screen
            .0
            .draw(|f| view::draw(f, &m))
            .map_err(|e| e.to_string())?;
        if event::poll(Duration::from_millis(250)).map_err(|e| e.to_string())?
            && let Event::Key(k) = event::read().map_err(|e| e.to_string())?
            && k.kind == KeyEventKind::Press
        {
            m.key(k, &src);
        }
        // a running job's lines every second, the rest every ten
        if ticked.elapsed() >= Duration::from_secs(1) {
            m.tick(&src);
            ticked = Instant::now();
        }
        if refreshed.elapsed() >= Duration::from_secs(10) && m.mode == model::Mode::Normal {
            m.refresh(&src);
            refreshed = Instant::now();
        }
    }
    Ok(String::new())
}

#[cfg(test)]
mod tests {
    use super::model::{Mode, Model, Screen};
    use super::source::Source;
    use super::view;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use serde_json::{Value, json};
    use std::cell::{Cell, RefCell};

    /// A daemon in memory: what its routes answer, and the POSTs it got.
    struct Fake {
        posts: RefCell<Vec<(String, Value)>>,
        answer: RefCell<(u16, Value)>,
        /// the daemon could not ask OSV
        osv_down: Cell<bool>,
        /// uptrack failed
        uptrack_down: Cell<bool>,
    }

    impl Fake {
        fn new() -> Fake {
            Fake {
                posts: RefCell::default(),
                answer: RefCell::new((200, json!({ "rev": 3, "job": 7, "commit": "abc" }))),
                osv_down: Cell::new(false),
                uptrack_down: Cell::new(false),
            }
        }
    }

    impl Source for Fake {
        fn get(&self, path: &str) -> Result<Value, String> {
            Ok(match path {
                "/auth/me" => json!({ "id": "dev:alice", "name": "alice", "level": "operator" }),
                "/systems/server/candidate" => json!({ "revision": 2, "ops": [
                    { "rev": 2, "module": "/services/sshd", "path": ["port"], "op": "set", "value": "2222", "by": { "name": "bob" } }],
                    "lock": null }),
                "/systems/server/machines" => json!({ "machines": [
                    { "name": "web1", "status": { "version": "20261105.1", "available": "20261106.1", "entries": [
                        { "version": "20261105.1", "selected": true, "default": true }] } },
                    { "name": "web2", "error": "Connection refused" }] }),
                "/systems/server/config" => {
                    json!({ "/system": { "version": { "value": "20261105.1", "explicit": true } },
                    "/services/sshd": { "port": { "value": 22, "explicit": true } } })
                }
                "/systems/server/config/services/sshd" => json!({ "options": [
                    { "module": "/services/sshd", "option": "port", "type": "integer", "value": 22, "explicit": true,
                      "default": 22, "description": "Listening port." }] }),
                "/systems/server/config/system" => json!({ "options": [] }),
                "/systems/server/packages" => json!({
                    "packages": [
                        { "name": "openssl", "version": "3.0.1", "origin": "repkgs", "root": false,
                          "advisories": [{ "id": "CVE-2022-0778", "severity": "HIGH" }],
                          "upstream": { "newest": "3.0.2", "outdated": true } },
                        { "name": "systemd", "version": "262.1", "origin": "golconda", "root": true,
                          "purl": "pkg:github/systemd/systemd@v262.1",
                          "advisories": null, "osvCovered": false }],
                    "advisories": { "checkedAt": 1,
                        "error": self.osv_down.get().then_some("connection refused") },
                    "upstream": { "checkedAt": 1, "running": false,
                        "error": self.uptrack_down.get().then_some("no network") } }),
                "/systems/server/changes" => json!({ "changes": [
                    { "module": "/services/sshd", "path": ["port"], "before": { "value": 22 }, "after": { "value": 2222 } }] }),
                "/jobs?system=server" => {
                    json!([{ "id": 7, "kind": "update", "machine": "web1", "state": "running" }])
                }
                "/jobs/7" => {
                    json!({ "job": { "id": 7, "kind": "update", "machine": "web1", "state": "ok" },
                    "lines": [{ "line": "Selected update '20261106.1' for install." }] })
                }
                p => return Err(format!("{p}: 404")),
            })
        }

        fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
            self.posts.borrow_mut().push((path.into(), body.clone()));
            Ok(self.answer.borrow().clone())
        }
    }

    fn key(m: &mut Model, src: &Fake, keys: &str) {
        for c in keys.chars() {
            let code = match c {
                '\n' => KeyCode::Enter,
                '\t' => KeyCode::Tab,
                '\x08' => KeyCode::Backspace,
                c => KeyCode::Char(c),
            };
            m.key(KeyEvent::new(code, KeyModifiers::NONE), src);
        }
    }

    fn screen(m: &Model) -> String {
        let mut t = Terminal::new(TestBackend::new(120, 20)).unwrap();
        t.draw(|f| view::draw(f, m)).unwrap();
        let b = t.backend().buffer().clone();
        (0..b.area.height)
            .map(|y| {
                (0..b.area.width)
                    .map(|x| b[(x, y)].symbol().to_string())
                    .collect::<String>()
                    + "\n"
            })
            .collect()
    }

    #[test]
    fn the_status_screen_shows_each_machine_and_starts_a_job_after_a_yes() {
        let src = Fake::new();
        let mut m = Model::new("server");
        m.refresh(&src);
        let s = screen(&m);
        assert!(s.contains("candidate: 1 change"), "{s}");
        assert!(
            s.contains("web1") && s.contains("20261106.1 at the source"),
            "{s}"
        );
        assert!(s.contains("unreachable: Connection refused"), "{s}");
        key(&mut m, &src, "u");
        assert!(screen(&m).contains("update web1? y/n"));
        key(&mut m, &src, "n");
        assert!(src.posts.borrow().is_empty(), "no is no");
        key(&mut m, &src, "uy");
        assert_eq!(
            src.posts.borrow()[0],
            (
                "/systems/server/jobs".into(),
                json!({ "kind": "update", "machine": "web1" })
            )
        );
        assert_eq!(m.screen, Screen::Jobs);
        assert!(screen(&m).contains("Selected update '20261106.1' for install."));
    }

    #[test]
    fn an_option_is_edited_into_the_candidate() {
        let src = Fake::new();
        let mut m = Model::new("server");
        key(&mut m, &src, "2");
        assert_eq!(m.modules, ["/services/sshd", "/system"]);
        assert!(screen(&m).contains("Listening port."));
        key(&mut m, &src, "\te");
        assert_eq!(
            m.mode,
            Mode::Edit {
                module: "/services/sshd".into(),
                option: "port".into(),
                buffer: "22".into()
            }
        );
        key(&mut m, &src, "\x08\x082200\n");
        assert_eq!(
            src.posts.borrow()[0],
            (
                "/systems/server/ops".into(),
                json!({ "base": 2, "module": "/services/sshd", "option": "port", "op": "set", "value": "2200" })
            )
        );
        assert_eq!(
            m.message,
            Some((false, "rev 3: set /services/sshd port = 2200".into()))
        );
        // text that is not TOML goes as a string, quoted
        key(&mut m, &src, "e");
        m.key(
            KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL),
            &src,
        );
        key(&mut m, &src, "any host\n");
        assert_eq!(src.posts.borrow()[1].1["value"], "\"any host\"");
    }

    #[test]
    fn refusals_are_said_plainly() {
        let src = Fake::new();
        let mut m = Model::new("server");
        key(&mut m, &src, "2\te");
        *src.answer.borrow_mut() = (
            409,
            json!({ "theirs": [{ "rev": 2, "by": { "name": "bob" } }] }),
        );
        key(&mut m, &src, "1\n");
        assert_eq!(m.message.as_ref().map(|x| x.0), Some(true));
        assert!(
            m.message
                .as_ref()
                .unwrap()
                .1
                .contains("conflict with rev 2 by bob")
        );
        *src.answer.borrow_mut() = (
            423,
            json!({ "lock": { "by": { "name": "bob" }, "until": "12:00" } }),
        );
        key(&mut m, &src, "e\n");
        assert_eq!(
            m.message.as_ref().unwrap().1,
            "bob holds the lock until 12:00"
        );
    }

    #[test]
    fn changes_commit_discard_and_the_lock() {
        let src = Fake::new();
        let mut m = Model::new("server");
        key(&mut m, &src, "4");
        let s = screen(&m);
        assert!(
            s.contains("- port = 22") && s.contains("+ port = 2222"),
            "{s}"
        );
        key(&mut m, &src, "cport 2222\n");
        assert_eq!(
            src.posts.borrow()[0],
            (
                "/systems/server/commit".into(),
                json!({ "message": "port 2222" })
            )
        );
        key(&mut m, &src, "xy");
        assert_eq!(src.posts.borrow()[1].0, "/systems/server/discard");
        key(&mut m, &src, "l");
        assert_eq!(
            src.posts.borrow()[2],
            ("/systems/server/lock".into(), json!({ "minutes": 30 }))
        );
        // someone else's lock: l says how to break it, B breaks it with a reason
        m.lock = json!({ "by": { "id": "dev:bob", "name": "bob" }, "until": "12:00" });
        key(&mut m, &src, "l");
        assert!(m.message.as_ref().unwrap().1.contains("bob holds the lock"));
        assert_eq!(src.posts.borrow().len(), 3);
        assert!(screen(&m).contains("locked by bob until 12:00"));
        key(&mut m, &src, "Bbob is away\n");
        assert_eq!(
            src.posts.borrow()[3],
            (
                "/systems/server/lock/break".into(),
                json!({ "reason": "bob is away" })
            )
        );
        key(&mut m, &src, "q");
        assert!(m.quit);
    }

    #[test]
    fn packages_list_from_the_sbom() {
        let src = Fake::new();
        let mut m = Model::new("server");
        key(&mut m, &src, "3");
        let s = screen(&m);
        assert!(s.contains("systemd") && s.contains("in the image"), "{s}");
        assert!(s.contains("CVE-2022-0778"), "{s}");
        assert!(s.contains("3.0.2"), "{s}");
        assert!(s.contains("not in OSV"), "{s}");
        assert!(!s.contains("could not check"), "{s}");
    }

    #[test]
    fn packages_say_when_osv_could_not_be_asked() {
        let src = Fake::new();
        src.osv_down.set(true);
        let mut m = Model::new("server");
        key(&mut m, &src, "3");
        let s = screen(&m);
        assert!(s.contains("could not check vulnerabilities"), "{s}");
        assert!(s.contains("systemd"), "{s}");
    }

    #[test]
    fn packages_say_when_uptrack_failed() {
        let src = Fake::new();
        src.uptrack_down.set(true);
        let mut m = Model::new("server");
        key(&mut m, &src, "3");
        let s = screen(&m);
        assert!(s.contains("could not check upstream versions"), "{s}");
        assert!(!s.contains("could not check vulnerabilities"), "{s}");
    }
}
