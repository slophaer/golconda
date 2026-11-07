//! The newest upstream version of the image's packages, from uptrack (repkgs' tool for
//! tracking upstream releases).
//!
//! uptrack learns versions only by asking the network, one process per tree of `sources.toml`
//! files (`UPTRACK_ROOT`), and it takes seconds to minutes. So a page view never waits for it:
//! [`Upstream::status`] answers from what is kept and, when an answer is missing or older than
//! the lifetime, starts one run in the background. Answers are kept in memory and in a file.

use crate::packages::Package;
use crate::vars::Program;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tempfile::NamedTempFile;
use toml_edit::{DocumentMut, Item};

/// What uptrack says about one package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// the newest version it knows (the pinned one when nothing is newer); none: it failed
    pub newest: Option<String>,
    /// a version newer than the tree's pin exists
    pub outdated: bool,
    /// the release date of `newest`, when it is newer and the datasource says
    pub released: Option<String>,
    /// why uptrack could not tell (a purl type it has no datasource for, a rate limit, …)
    pub error: Option<String>,
}

/// What is known now, and whether a run is under way.
#[derive(Debug, Clone, Default)]
pub struct Status {
    /// Unix time of the oldest answer used
    pub checked_at: Option<u64>,
    /// why the last run failed, if it did
    pub error: Option<String>,
    /// a run is asking the network right now
    pub running: bool,
    found: BTreeMap<String, Found>,
}

/// How long a failed run is left alone, so a page view does not start it again at once.
const RETRY: Duration = Duration::from_secs(300);
/// How long one uptrack run may take.
const LIMIT: Duration = Duration::from_mins(30);
/// Directories of a tree that never hold a package.
const SKIPPED: [&str; 3] = ["target", "node_modules", "result"];

/// What was asked about a package, and when. `found` is none for a package no tree tracks.
#[derive(Debug, Clone)]
struct Entry {
    at: u64,
    found: Option<Found>,
}

#[derive(Debug, Default)]
struct State {
    entries: BTreeMap<String, Entry>,
    /// the thread of the run under way: a run is under way while it has not ended, so a run
    /// that ends in a panic is over too, and no flag can stay set behind it
    run: Option<JoinHandle<()>>,
    /// when and why the last run failed, until a run succeeds
    failed: Option<(Instant, String)>,
}

impl State {
    /// Whether a run is under way. A run that has ended is collected; one that panicked
    /// counts as a failed run.
    fn settle(&mut self) -> bool {
        if self.run.as_ref().is_some_and(|h| !h.is_finished()) {
            return true;
        }
        if let Some(h) = self.run.take()
            && h.join().is_err()
        {
            self.failed = Some((Instant::now(), "the uptrack run ended in a panic".into()));
        }
        false
    }
}

/// One uptrack run on a tree: `Upstream::run`, or a stand-in in the tests.
type Ask = fn(&Upstream, &Path, &BTreeSet<String>) -> Result<Vec<(String, Found)>, String>;

pub struct Upstream {
    program: Program,
    trees: Vec<PathBuf>,
    file: Option<PathBuf>,
    lifetime: Duration,
    ask: Ask,
    state: Mutex<State>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

impl Found {
    pub fn to_json(&self) -> Value {
        json!({ "newest": self.newest, "outdated": self.outdated,
                "released": self.released, "error": self.error })
    }

    fn from_json(v: &Value) -> Found {
        let text = |k: &str| v[k].as_str().map(str::to_string);
        Found {
            newest: text("newest"),
            outdated: v["outdated"].as_bool().unwrap_or(false),
            released: text("released"),
            error: text("error"),
        }
    }

    /// One entry of `uptrack check --json`: `to` is the newer version, `from` the pinned one,
    /// `pin.date` the newer one's release date. A `note` with no `to` says why there is no
    /// answer (everything held back by `allow`, no versions listed).
    fn of_plan(entry: &Value) -> Found {
        let text = |v: &Value| v.as_str().map(str::to_string);
        let to = text(&entry["to"]);
        let error = text(&entry["error"]).or_else(|| text(&entry["note"]).filter(|_| to.is_none()));
        if error.is_some() {
            return Found {
                newest: None,
                outdated: false,
                released: None,
                error,
            };
        }
        Found {
            outdated: to.is_some(),
            released: to.as_ref().and_then(|_| text(&entry["pin"]["date"])),
            newest: to.or_else(|| text(&entry["from"])),
            error: None,
        }
    }
}

impl Status {
    /// What uptrack said about `p`; none when it tracks no such package or has not said yet.
    pub fn of(&self, p: &Package) -> Option<&Found> {
        self.found.get(&p.name)
    }

    pub fn outdated(&self, p: &Package) -> bool {
        self.of(p).is_some_and(|f| f.outdated)
    }
}

impl Upstream {
    /// `program` is uptrack and its leading arguments; `trees` are the directories holding
    /// the `sources.toml` files it is run on, one run each. Answers are kept `lifetime`, and
    /// in `file` when given.
    pub fn open(
        program: Program,
        trees: Vec<PathBuf>,
        file: Option<PathBuf>,
        lifetime: Duration,
    ) -> Arc<Upstream> {
        Upstream::open_asking(program, trees, file, lifetime, Upstream::run)
    }

    fn open_asking(
        program: Program,
        trees: Vec<PathBuf>,
        file: Option<PathBuf>,
        lifetime: Duration,
        ask: Ask,
    ) -> Arc<Upstream> {
        let entries = file.as_deref().map(read_entries).unwrap_or_default();
        Arc::new(Upstream {
            program,
            trees,
            file,
            lifetime,
            ask,
            state: Mutex::new(State {
                entries,
                ..State::default()
            }),
        })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// No run is under way.
    pub fn idle(&self) -> bool {
        !self.lock().settle()
    }

    /// What is kept about `list`, without starting a run.
    pub fn peek(&self, list: &[Package]) -> Status {
        Self::report(&mut self.lock(), list)
    }

    fn report(st: &mut State, list: &[Package]) -> Status {
        let running = st.settle();
        let mut status = Status {
            error: st.failed.as_ref().map(|(_, e)| e.clone()),
            running,
            ..Status::default()
        };
        for p in list {
            if let Some(Entry {
                at,
                found: Some(found),
            }) = st.entries.get(&p.name)
            {
                status.found.insert(p.name.clone(), found.clone());
                status.checked_at = Some(status.checked_at.map_or(*at, |c| c.min(*at)));
            }
        }
        status
    }

    /// Answers from what is kept; starts a run in the background for what is missing or old.
    pub fn status(self: &Arc<Self>, list: &[Package]) -> Status {
        let mut st = self.lock();
        let t = now();
        let lifetime = self.lifetime.as_secs();
        let stale: BTreeSet<String> = list
            .iter()
            .filter(|p| {
                st.entries
                    .get(&p.name)
                    .is_none_or(|e| t.saturating_sub(e.at) >= lifetime)
            })
            .map(|p| p.name.clone())
            .collect();
        // first: a run that has just ended in a panic is a failure to wait after
        let running = st.settle();
        let waiting = st
            .failed
            .as_ref()
            .is_some_and(|(at, _)| at.elapsed() < RETRY);
        if !stale.is_empty() && !running && !waiting {
            let up = self.clone();
            st.run = Some(thread::spawn(move || up.refresh(&stale)));
        }
        Self::report(&mut st, list)
    }

    /// Like [`Upstream::status`], but waits for the run it starts: for a command that is run
    /// once and has nothing else to do meanwhile.
    pub fn ask(self: &Arc<Self>, list: &[Package]) -> Status {
        self.status(list);
        while !self.idle() {
            thread::sleep(Duration::from_millis(50));
        }
        self.peek(list)
    }

    /// One run per tree, for the packages that tree tracks; then the answers are kept.
    fn refresh(&self, wanted: &BTreeSet<String>) {
        let mut left = wanted.clone();
        let (mut answers, mut errors) = (BTreeMap::new(), Vec::new());
        for tree in &self.trees {
            let tracked = tracked_in(tree, &left);
            if tracked.is_empty() {
                continue;
            }
            left.retain(|n| !tracked.contains(n));
            match (self.ask)(self, tree, &tracked) {
                Ok(found) => answers.extend(found),
                Err(e) => errors.push(format!("{}: {e}", tree.display())),
            }
        }
        let at = now();
        let mut st = self.lock();
        for (name, found) in answers {
            st.entries.insert(
                name,
                Entry {
                    at,
                    found: Some(found),
                },
            );
        }
        // tracked by no tree: nothing to ask, and nothing to look for again until the lifetime
        for name in left {
            st.entries.insert(name, Entry { at, found: None });
        }
        st.failed = (!errors.is_empty()).then(|| (Instant::now(), errors.join("; ")));
        if let Some(file) = &self.file {
            write_entries(file, &st.entries);
        }
    }

    fn run(&self, tree: &Path, names: &BTreeSet<String>) -> Result<Vec<(String, Found)>, String> {
        let mut args: Vec<&str> = vec!["check"];
        args.extend(names.iter().map(String::as_str));
        args.push("--json");
        let out = (self.program)
            .with_env("UPTRACK_ROOT", tree)
            .run_within(&args, LIMIT)
            .map_err(|e| e.to_string())?;
        let plan: Value = serde_json::from_slice(&out).map_err(|e| format!("no JSON: {e}"))?;
        let plan = plan.as_array().ok_or("not a list")?;
        Ok(names
            .iter()
            .map(|name| {
                let found = plan
                    .iter()
                    .find(|e| e["name"] == name.as_str())
                    .map_or_else(
                        || Found {
                            newest: None,
                            outdated: false,
                            released: None,
                            error: Some("uptrack did not report it".into()),
                        },
                        Found::of_plan,
                    );
                (name.clone(), found)
            })
            .collect())
    }
}

/// The names in `wanted` that a `sources.toml` under `tree` tracks: the directory's name, with
/// an `[upstream] purl` (uptrack refuses a name that has none).
fn tracked_in(tree: &Path, wanted: &BTreeSet<String>) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    let mut todo = vec![tree.to_path_buf()];
    while let Some(dir) = todo.pop() {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let is_dir = entry.file_type().is_ok_and(|t| t.is_dir());
            if is_dir && !name.starts_with('.') && !SKIPPED.contains(&name.as_str()) {
                todo.push(entry.path());
            }
        }
        let Some(package) = dir.file_name().map(|n| n.to_string_lossy().into_owned()) else {
            continue;
        };
        let tracks = fs::read_to_string(dir.join("sources.toml"))
            .ok()
            .and_then(|t| t.parse::<DocumentMut>().ok())
            .is_some_and(|doc| {
                doc.get("upstream")
                    .and_then(|u| u.get("purl"))
                    .is_some_and(Item::is_str)
            });
        if tracks && wanted.contains(&package) {
            found.insert(package);
        }
    }
    found
}

fn read_entries(file: &Path) -> BTreeMap<String, Entry> {
    let v: Value = fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    v.as_object()
        .into_iter()
        .flatten()
        .filter_map(|(name, e)| {
            let at = e["at"].as_u64()?;
            let found = e["found"]
                .is_object()
                .then(|| Found::from_json(&e["found"]));
            Some((name.clone(), Entry { at, found }))
        })
        .collect()
}

/// Written beside and renamed; a failure leaves the answers in memory, which is enough.
fn write_entries(file: &Path, entries: &BTreeMap<String, Entry>) {
    let doc: Map<String, Value> = entries
        .iter()
        .map(|(name, e)| {
            let found = e.found.as_ref().map(Found::to_json);
            (name.clone(), json!({ "at": e.at, "found": found }))
        })
        .collect();
    let dir = file.parent().unwrap_or(Path::new("."));
    let written = fs::create_dir_all(dir)
        .and_then(|()| NamedTempFile::new_in(dir))
        .and_then(|mut t| {
            t.write_all(Value::Object(doc).to_string().as_bytes())?;
            t.persist(file).map_err(|e| e.error)
        });
    drop(written);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::thread;
    use std::time::Instant;
    use tempfile::TempDir;

    fn pkg(name: &str, version: &str) -> Package {
        Package {
            name: name.into(),
            version: version.into(),
            origin: None,
            purl: None,
            cpe: None,
            root: false,
            replaces: vec![],
            pinned: None,
        }
    }

    /// A stand-in for uptrack: logs "ROOT ARGS" for each run, then prints `plan.json` from its
    /// directory, or fails when a file `fail-<name of the root>` is there.
    struct Scene {
        dir: TempDir,
    }

    impl Scene {
        fn new(plan: &serde_json::Value) -> Scene {
            let dir = TempDir::new().unwrap();
            let d = dir.path();
            fs::write(d.join("plan.json"), plan.to_string()).unwrap();
            let script = d.join("uptrack");
            fs::write(
                &script,
                format!(
                    "#!/bin/sh\necho \"$UPTRACK_ROOT $*\" >> {d}/log\n\
                     [ -f {d}/pause ] && sleep 1\n\
                     if [ -f \"{d}/fail-$(basename \"$UPTRACK_ROOT\")\" ]; then echo 'sources.toml: unknown upstream keys url' >&2; exit 1; fi\n\
                     cat {d}/plan.json\n",
                    d = d.display()
                ),
            )
            .unwrap();
            fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
            Scene { dir }
        }

        fn path(&self) -> &Path {
            self.dir.path()
        }

        fn program(&self) -> Program {
            Program::new(vec![self.path().join("uptrack").into_os_string()])
        }

        /// A tree with these packages: (directory, sources.toml).
        fn tree(&self, name: &str, packages: &[(&str, &str)]) -> PathBuf {
            let root = self.path().join(name);
            for (rel, toml) in packages {
                fs::create_dir_all(root.join(rel)).unwrap();
                fs::write(root.join(rel).join("sources.toml"), toml).unwrap();
            }
            root
        }

        fn runs(&self) -> Vec<String> {
            fs::read_to_string(self.path().join("log"))
                .unwrap_or_default()
                .lines()
                .map(str::to_string)
                .collect()
        }
    }

    const TRACKED: &str = "[upstream]\npurl = \"pkg:github/x/y\"\n[pin]\nversion = \"1\"\n";
    const FROZEN: &str = "[upstream]\nfrozen = \"dead upstream\"\n[pin]\nversion = \"1\"\n";

    fn plan() -> serde_json::Value {
        json!([
            { "name": "jq", "from": "1.7", "to": "1.8.2", "note": "released 2026-10-01",
              "pin": { "version": "1.8.2", "date": "2026-10-01" }, "candidates": [{ "version": "1.8.2" }] },
            { "name": "acl", "from": "2.4.0", "to": null, "note": null, "error": null },
            { "name": "dash", "from": "0.5", "to": null, "note": "no datasource for purl type deb",
              "error": "no datasource for purl type deb" },
        ])
    }

    fn image() -> Vec<Package> {
        ["acl", "dash", "frozen", "jq", "nowhere"]
            .iter()
            .map(|n| pkg(n, "1"))
            .collect()
    }

    fn standard(scene: &Scene) -> PathBuf {
        scene.tree(
            "pkgs",
            &[
                ("ac/acl", TRACKED),
                ("da/dash", TRACKED),
                ("fr/frozen", FROZEN),
                ("jq/jq", TRACKED),
                ("zz/unused", TRACKED),
            ],
        )
    }

    /// What is kept once the run under way is over.
    fn settled(up: &Arc<Upstream>, list: &[Package]) -> Status {
        let started = Instant::now();
        while !up.idle() {
            assert!(
                started.elapsed() < Duration::from_secs(20),
                "the run never ended"
            );
            thread::sleep(Duration::from_millis(20));
        }
        up.peek(list)
    }

    /// A page view, and the run it starts, to its end.
    fn ran(up: &Arc<Upstream>, list: &[Package]) -> Status {
        let started = Instant::now();
        let status = up.ask(list);
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "the run never ended"
        );
        status
    }

    #[test]
    fn a_page_view_starts_a_run_and_does_not_wait_for_it() {
        let scene = Scene::new(&plan());
        fs::write(scene.path().join("pause"), "").unwrap();
        let tree = standard(&scene);
        let up = Upstream::open(scene.program(), vec![tree], None, Duration::from_hours(6));
        let list = image();
        let started = Instant::now();
        let first = up.status(&list);
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "waited for uptrack"
        );
        assert!(first.running);
        assert!(first.of(&list[3]).is_none() && first.checked_at.is_none());
        // a view during the run starts no second one
        assert!(up.status(&list).running);
        let done = settled(&up, &list);
        assert_eq!(scene.runs().len(), 1, "{:?}", scene.runs());
        assert_eq!(done.error, None);
        assert!(done.checked_at.is_some());
    }

    #[test]
    fn it_asks_uptrack_for_the_packages_the_tree_tracks_and_reads_the_plan() {
        let scene = Scene::new(&plan());
        let tree = standard(&scene);
        let up = Upstream::open(
            scene.program(),
            vec![tree.clone()],
            None,
            Duration::from_hours(6),
        );
        let list = image();
        let s = ran(&up, &list);
        // names the tree tracks, sorted; not the frozen one, not the one it lacks
        assert_eq!(
            scene.runs(),
            [format!("{} check acl dash jq --json", tree.display())]
        );
        let jq = s.of(&list[3]).unwrap();
        assert_eq!(
            jq,
            &Found {
                newest: Some("1.8.2".into()),
                outdated: true,
                released: Some("2026-10-01".into()),
                error: None
            }
        );
        let acl = s.of(&list[0]).unwrap();
        assert_eq!(
            (acl.newest.as_deref(), acl.outdated),
            (Some("2.4.0"), false)
        );
        let dash = s.of(&list[1]).unwrap();
        assert_eq!(dash.newest, None);
        assert_eq!(
            dash.error.as_deref(),
            Some("no datasource for purl type deb")
        );
        assert!(s.of(&list[2]).is_none() && s.of(&list[4]).is_none());
        assert!(s.outdated(&list[3]) && !s.outdated(&list[0]) && !s.outdated(&list[1]));
        assert_eq!(jq.to_json()["newest"], "1.8.2");
    }

    #[test]
    fn answers_are_kept_for_the_lifetime_and_across_restarts() {
        let scene = Scene::new(&plan());
        let tree = standard(&scene);
        let file = scene.path().join("upstream.json");
        let list = image();
        let up = Upstream::open(
            scene.program(),
            vec![tree.clone()],
            Some(file.clone()),
            Duration::from_hours(6),
        );
        ran(&up, &list);
        for _ in 0..3 {
            assert!(!up.status(&list).running);
        }
        assert_eq!(scene.runs().len(), 1);
        // a restarted daemon reads the file: no run, and the answers are there
        let again = Upstream::open(
            scene.program(),
            vec![tree],
            Some(file),
            Duration::from_hours(6),
        );
        let s = again.status(&list);
        assert!(
            !s.running && s.of(&list[3]).is_some_and(|f| f.outdated),
            "{s:?}"
        );
        assert_eq!(scene.runs().len(), 1);
    }

    #[test]
    fn an_old_answer_is_asked_for_again_and_shown_meanwhile() {
        let scene = Scene::new(&plan());
        let tree = standard(&scene);
        let up = Upstream::open(scene.program(), vec![tree], None, Duration::ZERO);
        let list = image();
        ran(&up, &list);
        let s = up.status(&list);
        assert!(s.running, "too old: asked again");
        assert!(s.of(&list[3]).is_some(), "the old answer shows meanwhile");
        ran(&up, &list);
        assert_eq!(scene.runs().len(), 2);
    }

    #[test]
    fn a_tree_that_uptrack_refuses_is_an_error_and_not_tried_again_at_once() {
        let scene = Scene::new(&plan());
        let tree = standard(&scene);
        fs::write(scene.path().join("fail-pkgs"), "").unwrap();
        let up = Upstream::open(scene.program(), vec![tree], None, Duration::from_hours(6));
        let list = image();
        let s = ran(&up, &list);
        let e = s.error.clone().expect("an error");
        assert!(e.contains("unknown upstream keys url"), "{e}");
        assert!(s.of(&list[3]).is_none() && s.checked_at.is_none());
        let again = up.status(&list);
        assert!(!again.running && again.error.is_some());
        assert_eq!(scene.runs().len(), 1);
    }

    #[test]
    fn one_tree_failing_leaves_the_others_answers() {
        let scene = Scene::new(&plan());
        let golconda = scene.tree("packages", &[("jq", TRACKED)]);
        let repkgs = scene.tree("repkgs", &[("ac/acl", TRACKED), ("da/dash", TRACKED)]);
        fs::write(scene.path().join("fail-packages"), "").unwrap();
        let up = Upstream::open(
            scene.program(),
            vec![golconda, repkgs],
            None,
            Duration::from_hours(6),
        );
        let list = image();
        let s = ran(&up, &list);
        assert!(
            s.error.as_deref().is_some_and(|e| e.contains("packages")),
            "{s:?}"
        );
        assert!(s.of(&list[3]).is_none(), "jq is in the tree that failed");
        assert_eq!(s.of(&list[0]).unwrap().newest.as_deref(), Some("2.4.0"));
        assert_eq!(scene.runs().len(), 2);
    }

    #[test]
    fn an_old_answer_stays_when_the_next_run_fails() {
        let scene = Scene::new(&plan());
        let tree = standard(&scene);
        let up = Upstream::open(scene.program(), vec![tree], None, Duration::ZERO);
        let list = image();
        ran(&up, &list);
        fs::write(scene.path().join("fail-pkgs"), "").unwrap();
        up.status(&list);
        let s = ran(&up, &list);
        assert!(s.error.is_some());
        assert!(s.outdated(&list[3]) && s.checked_at.is_some());
    }

    #[test]
    fn a_program_that_is_not_there_is_an_error() {
        let scene = Scene::new(&plan());
        let tree = standard(&scene);
        let missing = Program::new(vec![scene.path().join("nope").into_os_string()]);
        let up = Upstream::open(missing, vec![tree], None, Duration::from_hours(6));
        let s = ran(&up, &image());
        assert!(s.error.is_some_and(|e| e.contains("cannot run")));
    }

    #[test]
    fn packages_no_tree_has_are_not_asked_about_again() {
        let scene = Scene::new(&plan());
        let tree = scene.tree("pkgs", &[("zz/unused", TRACKED)]);
        let up = Upstream::open(scene.program(), vec![tree], None, Duration::from_hours(6));
        let list = image();
        let s = ran(&up, &list);
        assert!(s.of(&list[0]).is_none() && s.error.is_none());
        assert!(scene.runs().is_empty(), "nothing to ask uptrack");
        assert!(!up.status(&list).running, "and no second look");
    }

    fn panics(
        _: &Upstream,
        _: &Path,
        _: &BTreeSet<String>,
    ) -> Result<Vec<(String, Found)>, String> {
        panic!("an answer the code did not expect");
    }

    #[test]
    fn a_run_that_panics_is_over_says_so_and_waits_before_the_next() {
        let scene = Scene::new(&json!([]));
        let tree = scene.tree("repkgs", &[("pkgs/x/x", TRACKED)]);
        let up = Upstream::open_asking(scene.program(), vec![tree], None, Duration::ZERO, panics);
        let list = [pkg("x", "1")];
        up.status(&list);
        // wait for the thread to end without looking at the state, which would settle it
        let start = Instant::now();
        while !up.lock().run.as_ref().is_some_and(JoinHandle::is_finished) {
            assert!(
                start.elapsed() < Duration::from_secs(5),
                "the run never ended"
            );
            thread::sleep(Duration::from_millis(10));
        }
        // the next view finds it over, says why, and starts no new run: a panic is a failure,
        // and a failure waits its pause
        let st = up.status(&list);
        assert!(!st.running, "a new run started at once");
        assert!(
            st.error.as_deref().is_some_and(|e| e.contains("panic")),
            "{st:?}"
        );
        assert!(up.idle());
    }
}
