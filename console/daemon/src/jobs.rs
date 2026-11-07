//! Jobs on machines: update, reboot, roll back, and deploy, the whole pipeline.
//!
//! Each system has one queue: its jobs run one after the other, so a machine never runs two at
//! once and a deploy is never overtaken. A job's state and output lines go to `jobs.db`, and its
//! start and end to the audit log. A deploy builds a release in the system's checkout (a signed
//! release commit, pushed), publishes it to the system's update source, then updates, reboots and
//! confirms one machine after the other, and stops at the first that fails.

use crate::app::{App, Identity};
use crate::locked;
use crate::write::{Outcome, Writes, may_write, operator, repo_of};
use golconda_core::audit::Entry;
use golconda_core::jobs::{Job, Jobs};
use golconda_core::machine::{self, Fleet, Machine, Patience, Remote};
use golconda_core::release::{self, BuildRequest, Destination, Tools};
use golconda_core::vars::Program;
use serde_json::json;
use std::collections::HashMap;
use std::ffi::OsString;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

/// What a job can be. `deploy` is the system's; the others take a machine.
pub const KINDS: [&str; 4] = ["update", "reboot", "rollback", "deploy"];

/// The programs and settings jobs run with.
pub struct JobConfig {
    pub ssh: Program,
    pub nix_build: Program,
    pub gpgv: Program,
    pub rclone: Program,
    /// the key set releases are signed with; none: no deploy
    pub release_keys: Option<PathBuf>,
    pub copy_keys: bool,
    pub patience: Patience,
}

pub struct Runner {
    pub store: Mutex<Jobs>,
    queues: Mutex<HashMap<String, mpsc::Sender<i64>>>,
    pub config: JobConfig,
}

impl Runner {
    /// `<state>/jobs.db`; the jobs a previous run left unended are interrupted.
    pub fn open(state: &Path, config: JobConfig) -> Result<Runner, String> {
        let store = Jobs::open(&state.join("jobs.db")).map_err(|e| e.to_string())?;
        Ok(Runner {
            store: Mutex::new(store),
            queues: Mutex::default(),
            config,
        })
    }
}

/// The machines of the system whose document is `doc`: `machines.toml` beside it, the entry
/// of `system` (none there: no machines).
pub fn fleet(doc: &Path, system: &str) -> Result<Fleet, String> {
    let path = doc.parent().unwrap_or(Path::new(".")).join("machines.toml");
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(Fleet::default()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let mut all = machine::parse(&text).map_err(|e| e.0)?;
    Ok(all.remove(system).unwrap_or_default())
}

/// Queues a job of `kind` on `system` (and `machine`, for all but deploy) for `who`.
pub fn submit(
    app: &Arc<App>,
    who: &Identity,
    via: &str,
    system: &str,
    kind: &str,
    machine: Option<&str>,
) -> Outcome {
    let (Some(w), Some(r)) = (&app.writes, &app.jobs) else {
        return Outcome::Bad("this daemon runs no jobs: it has no --state".into());
    };
    if !KINDS.contains(&kind) {
        return Outcome::Bad(format!("no job {kind}: {}", KINDS.join(", ")));
    }
    if let Some(o) = may_write(app, w, who, via, &format!("job.{kind}"), system) {
        return o;
    }
    let Some(doc) = app.document(system) else {
        return Outcome::Bad(format!("no system {system}"));
    };
    let f = match fleet(doc, system) {
        Ok(f) => f,
        Err(e) => return Outcome::Failed(e),
    };
    let machine = match (kind, machine.filter(|m| !m.is_empty())) {
        ("deploy", None) => {
            if f.updates.is_none() || r.config.release_keys.is_none() || f.machines.is_empty() {
                return Outcome::Bad(format!(
                    "a deploy needs {system}'s updates and machines in machines.toml, and --release-keys"
                ));
            }
            None
        }
        ("deploy", Some(_)) => return Outcome::Bad("a deploy is the whole system's".into()),
        (_, Some(m)) if f.machines.contains_key(m) => Some(m),
        (_, Some(m)) => return Outcome::Bad(format!("{system} has no machine {m}")),
        (_, None) => return Outcome::Bad(format!("a job {kind} needs a machine")),
    };
    let by = operator(who);
    let id = match locked(&r.store).create(kind, system, machine, &by) {
        Ok(id) => id,
        Err(e) => return Outcome::Failed(e.to_string()),
    };
    let e = Entry {
        system: Some(system.into()),
        target: Some(target(id, machine)),
        ..Entry::new(&by, via, &format!("job.{kind}"), "queued")
    };
    if let Err(err) = w.record(&e) {
        // an action that cannot be recorded does not happen
        let _ = locked(&r.store).end(id, false, "its audit entry could not be written");
        return Outcome::Failed(err);
    }
    enqueue(app, system, id);
    Outcome::Done(json!({ "job": id }))
}

fn target(id: i64, machine: Option<&str>) -> String {
    match machine {
        Some(m) => format!("job {id} on {m}"),
        None => format!("job {id}"),
    }
}

fn enqueue(app: &Arc<App>, system: &str, id: i64) {
    let Some(r) = &app.jobs else { return };
    let mut queues = locked(&r.queues);
    let tx = queues.entry(system.to_string()).or_insert_with(|| {
        let (tx, rx) = mpsc::channel::<i64>();
        let a = app.clone();
        thread::spawn(move || {
            for id in rx {
                run(&a, id);
            }
        });
        tx
    });
    // the worker lives as long as the daemon: a send cannot fail
    let _ = tx.send(id);
}

fn run(app: &App, id: i64) {
    let (Some(w), Some(r)) = (&app.writes, &app.jobs) else {
        return;
    };
    let Ok(job) = locked(&r.store).get(id) else {
        return;
    };
    let _ = locked(&r.store).start(id);
    let mut log = |line: &str| {
        let _ = locked(&r.store).log(id, line);
        app.events
            .send(&job.system, "job", json!({ "id": id, "line": line }));
    };
    let done = perform(app, w, r, &job, &mut log);
    let (ok, summary) = match &done {
        Ok(s) => (true, s.clone()),
        Err(e) => (false, e.clone()),
    };
    log(&summary);
    // the audit entry first: once the job shows as ended, its entry is there
    let e = Entry {
        system: Some(job.system.clone()),
        target: Some(format!("{}: {summary}", target(id, job.machine.as_deref()))),
        ..Entry::new(
            &job.by,
            "job",
            &format!("job.{}", job.kind),
            if ok { "ok" } else { "failed" },
        )
    };
    if let Err(err) = w.record(&e) {
        eprintln!("golcondad: the audit entry of job {id}: {err}");
    }
    let _ = locked(&r.store).end(id, ok, &summary);
    app.events.send(
        &job.system,
        "job",
        json!({ "id": id, "state": if ok { "ok" } else { "failed" }, "summary": summary }),
    );
}

fn perform(
    app: &App,
    w: &Writes,
    r: &Runner,
    job: &Job,
    log: &mut dyn FnMut(&str),
) -> Result<String, String> {
    let doc = app
        .document(&job.system)
        .ok_or_else(|| format!("no system {}", job.system))?;
    let f = fleet(doc, &job.system)?;
    let remote = Remote { ssh: &r.config.ssh };
    let one = |name: &Option<String>| -> Result<Machine, String> {
        let name = name.as_deref().unwrap_or("");
        f.machines
            .get(name)
            .cloned()
            .ok_or_else(|| format!("{} has no machine {name} any more", job.system))
    };
    match job.kind.as_str() {
        "update" => {
            let m = one(&job.machine)?;
            remote.update(&m, log).map_err(|e| e.0)?;
            let st = remote.status(&m).map_err(|e| e.0)?;
            let next = next_version(&st).unwrap_or_default();
            Ok(format!("{}: {next} is installed for the next boot", m.name))
        }
        "reboot" => {
            let m = one(&job.machine)?;
            let st = remote.status(&m).map_err(|e| e.0)?;
            let next = next_version(&st).unwrap_or_default();
            remote.reboot(&m, log).map_err(|e| e.0)?;
            machine::confirm(&remote, &m, &st.boot_id, &next, &r.config.patience, log)
                .map_err(|e| e.0)?;
            Ok(format!("{} runs {next}", m.name))
        }
        "rollback" => {
            let m = one(&job.machine)?;
            let st = remote.status(&m).map_err(|e| e.0)?;
            let back = remote.rollback(&m, log).map_err(|e| e.0)?;
            machine::confirm(&remote, &m, &st.boot_id, &back, &r.config.patience, log)
                .map_err(|e| e.0)?;
            Ok(format!("{} runs {back} again", m.name))
        }
        "deploy" => deploy(app, w, r, job, &f, doc, log),
        k => Err(format!("no job {k}")),
    }
}

/// The version the loader boots next: its default image entry's.
fn next_version(st: &machine::Status) -> Option<String> {
    st.entries
        .iter()
        .find(|e| e.default && e.is_image())
        .or_else(|| st.booted())
        .and_then(|e| e.version.clone())
}

/// git as the daemon commits: its own name, and its key when it signs.
fn daemon_git(w: &Writes) -> Program {
    let mut argv: Vec<OsString> = vec!["git".into()];
    let mut c = |k: &str, v: &str| {
        argv.push("-c".into());
        argv.push(format!("{k}={v}").into());
    };
    c("user.name", &w.committer.name);
    c("user.email", &w.committer.id);
    if let Some(key) = &w.signing_key {
        c("gpg.format", "ssh");
        c("user.signingKey", &key.to_string_lossy());
        c("commit.gpgSign", "true");
    }
    Program::new(argv)
}

fn deploy(
    app: &App,
    writes: &Writes,
    runner: &Runner,
    job: &Job,
    fleet: &Fleet,
    doc: &Path,
    log: &mut dyn FnMut(&str),
) -> Result<String, String> {
    let (Some(to), Some(keys)) = (&fleet.updates, &runner.config.release_keys) else {
        return Err("no update source or no --release-keys".into());
    };
    let git = daemon_git(writes);
    let dest = Destination {
        rclone: &runner.config.rclone,
        to,
    };
    log(&format!("building {} for {to}", job.system));
    let built = {
        let _checkout = locked(&writes.checkout);
        let req = BuildRequest {
            document: doc,
            system: &app.platform,
            keys,
            copy_keys: runner.config.copy_keys,
            version: None,
            dest: Some(&dest),
            out_link: writes.state.join("releases").join(&job.system),
            author: Some(format!("{} <{}>", job.by.name, job.by.id)),
        };
        let tools = Tools {
            nix_build: &runner.config.nix_build,
            git: &git,
            gpgv: &runner.config.gpgv,
        };
        let _ = fs::create_dir_all(writes.state.join("releases"));
        let made = release::build(&req, &tools).map_err(|e| e.0)?;
        // the entry before the push, as for a configuration commit: when it cannot be written,
        // the release commit goes again and nothing leaves the checkout
        let e = Entry {
            system: Some(job.system.clone()),
            target: Some(made.record.version.to_string()),
            config_commit: Some(made.record.commit.clone()),
            ..Entry::new(&job.by, "job", "release.build", "ok")
        };
        let repo = repo_of(writes, doc);
        if let Err(err) = writes.record(&e) {
            if let Ok((g, _, _)) = &repo {
                let _ = g.run(&["reset", "--hard", "HEAD~1"]);
            }
            return Err(format!(
                "the release commit is undone: its audit entry: {err}"
            ));
        }
        if let (Some(remote), Ok((g, _, branch))) = (&writes.push, &repo) {
            match g.push(remote, branch) {
                Ok(()) => log(&format!("release commit {} pushed", made.record.commit)),
                Err(e) => log(&format!(
                    "release commit {} not pushed: {e}",
                    made.record.commit
                )),
            }
        }
        made
    };
    let version = built.record.version;
    log(&format!(
        "built {} {version}: release commit {}",
        built.record.id, built.record.commit
    ));
    // the release commit is in the system's checkout
    let checkout = doc.parent().unwrap_or(Path::new("."));
    release::publish(&built.release, &dest, &git, checkout, false).map_err(|e| e.0)?;
    let e = Entry {
        system: Some(job.system.clone()),
        target: Some(format!("{version} to {to}")),
        ..Entry::new(&job.by, "job", "release.publish", "ok")
    };
    writes.record(&e)?;
    log(&format!("published {version} to {to}"));
    let remote = Remote {
        ssh: &runner.config.ssh,
    };
    let mut done = Vec::new();
    for m in fleet.machines.values() {
        let st = remote.status(m).map_err(|e| e.0)?;
        log(&format!(
            "{}: runs {}",
            m.name,
            st.version.clone().unwrap_or_default()
        ));
        remote.update(m, log).map_err(|e| e.0)?;
        remote.reboot(m, log).map_err(|e| e.0)?;
        machine::confirm(
            &remote,
            m,
            &st.boot_id,
            &version.to_string(),
            &runner.config.patience,
            log,
        )
        .map_err(|e| format!("{e}; {} not updated", rest(fleet, &done, &m.name)))?;
        done.push(m.name.clone());
    }
    Ok(format!("{} {version} on {}", job.system, done.join(", ")))
}

/// The machines a failed deploy did not get to.
fn rest(f: &Fleet, done: &[String], failed: &str) -> String {
    let left: Vec<&str> = f
        .machines
        .keys()
        .map(String::as_str)
        .filter(|m| *m != failed && !done.iter().any(|d| d == m))
        .collect();
    if left.is_empty() {
        "no other machine".into()
    } else {
        left.join(", ")
    }
}
