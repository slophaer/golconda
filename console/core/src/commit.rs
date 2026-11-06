//! Commit: the candidate's operations into the document, one signed git commit, pushed
//!
//! First the remote: a commit there that the checkout does not have is an outside change.
//! The checkout fast-forwards to it, the journal records its paths (from the semantic diff)
//! as operations by `outside`, and an open operation that touches one of them stops the
//! commit, as any conflict would. Then the candidate's text replaces the document, which must
//! pass the schema and evaluate; one commit holds it, by the operator who commits, with every
//! other operator whose operations it holds as `Co-authored-by:`, the daemon as the committer,
//! signed with the daemon's key. A push that fails leaves the commit local, not pushed; the
//! daemon pushes it later (`push`).

use crate::candidate::{Journal, Op, Operator, Refused, overlaps};
use crate::check;
use crate::diff::diff;
use crate::document::to_json;
use crate::eval;
use crate::git::{self, Git, Person};
use crate::system;
use serde_json::{Map, Value};
use std::fs;
use std::io;
use std::path::Path;

/// What the commit needs to evaluate: the effective configuration of a document (for the
/// diff of an outside change) and the full check of one (schema, then evaluation).
pub trait Evaluate {
    /// mkSystem's config of `text`, evaluated as the document at `document`
    fn config(&self, document: &Path, text: &str) -> Result<Value, String>;
    /// the document at `document` passes the schema and evaluates
    fn check(&self, document: &Path) -> Result<(), String>;
}

/// Evaluation through iets, as everywhere else.
pub struct Iets<'a> {
    pub iets: &'a eval::Iets,
    /// the Nix system to evaluate for
    pub platform: &'a str,
}

impl Evaluate for Iets<'_> {
    fn config(&self, document: &Path, text: &str) -> Result<Value, String> {
        system::System::load_text(self.iets, document, text, self.platform)
            .map(|s| s.config)
            .map_err(|e| e.to_string())
    }

    fn check(&self, document: &Path) -> Result<(), String> {
        check::validate(self.iets, document, self.platform).map_err(|e| e.to_string())
    }
}

/// Where a system's document lives in git.
pub struct Repo<'a> {
    pub git: &'a Git,
    /// the document, relative to the checkout
    pub document: &'a Path,
    /// the remote and branch to fetch from and push to; none: local only
    pub remote: Option<(&'a str, &'a str)>,
}

#[derive(Debug)]
pub struct Committed {
    pub id: String,
    /// the operations it holds
    pub ops: Vec<Op>,
    /// the outside changes it was fetched on top of
    pub outside: Vec<Op>,
    pub pushed: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("nothing to commit")]
    Nothing,
    /// open operations touch paths an outside change touched
    #[error("an outside change touched what the candidate changes: {}", .outside.iter().map(|o| format!("{} by {}", o.summary(), o.by.name)).collect::<Vec<_>>().join("; "))]
    Conflict { outside: Vec<Op>, yours: Vec<Op> },
    /// the remote and the checkout both have commits the other lacks
    #[error("the checkout and {0} have diverged")]
    Diverged(String),
    #[error("the candidate does not check: {0}")]
    Invalid(String),
    #[error("evaluating the outside change: {0}")]
    Outside(String),
    #[error(transparent)]
    Git(#[from] git::Error),
    #[error(transparent)]
    Journal(#[from] Refused),
    #[error("the document: {0}")]
    Io(#[from] io::Error),
    /// the record of the commit (its audit entry) could not be written: it was undone
    #[error("not recorded, so not committed: {0}")]
    Record(String),
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Error {
        Error::Journal(Refused::Journal(e))
    }
}

/// Bring the checkout up to the remote. Its new commits become outside changes in the
/// journal; those it recorded.
pub fn fetch(
    journal: &mut Journal,
    repo: &Repo,
    eval: &dyn Evaluate,
    system: &str,
) -> Result<Vec<Op>, Error> {
    let Some((remote, branch)) = repo.remote else {
        return Ok(Vec::new());
    };
    let git = repo.git;
    let (head, tip) = (git.head()?, git.fetch(remote, branch)?);
    if head == tip || git.is_ancestor(&tip, &head)? {
        // nothing new there (ours may be ahead: not pushed yet)
        return Ok(Vec::new());
    }
    if !git.is_ancestor(&head, &tip)? {
        return Err(Error::Diverged(format!("{remote} {branch}")));
    }
    let before = git.show(&head, repo.document)?;
    let after = git.show(&tip, repo.document)?;
    let authors = git.authors(&head, &tip)?;
    git.run(&["merge", "--quiet", "--ff-only", &tip])?;
    let path = git.dir.join(repo.document);
    let (b, a) = (
        eval.config(&path, &before).map_err(Error::Outside)?,
        eval.config(&path, &after).map_err(Error::Outside)?,
    );
    let names: Vec<String> = authors.iter().map(Person::line).collect();
    let by = Operator {
        id: "outside".into(),
        name: if names.is_empty() {
            "outside".into()
        } else {
            names.join(", ")
        },
    };
    Ok(journal.record_outside(system, &diff(&b, &a), &by, &tip)?)
}

/// Commit the candidate of `system`: `by` pressed Commit, `text` is their message.
pub fn commit(
    journal: &mut Journal,
    repo: &Repo,
    eval: &dyn Evaluate,
    system: &str,
    by: &Operator,
    text: &str,
) -> Result<Committed, Error> {
    commit_with(journal, repo, eval, system, by, text, |_| Ok(()))
}

/// `commit`, with `record` run on the commit before it is pushed: the audit entry, which
/// names the commit, so it can only come after it. If it fails, the commit is undone (the
/// branch and the document as before, the operations open) and nothing is pushed.
pub fn commit_with(
    journal: &mut Journal,
    repo: &Repo,
    eval: &dyn Evaluate,
    system: &str,
    by: &Operator,
    text: &str,
    record: impl FnOnce(&Committed) -> Result<(), String>,
) -> Result<Committed, Error> {
    let outside = fetch(journal, repo, eval, system)?;
    let open = journal.open_ops(system)?;
    let yours: Vec<Op> = open
        .iter()
        .filter(|o| {
            outside
                .iter()
                .any(|x| overlaps(&x.module, &x.path, &o.module, &o.path))
        })
        .cloned()
        .collect();
    if !yours.is_empty() {
        return Err(Error::Conflict { outside, yours });
    }
    if open.is_empty() {
        return Err(Error::Nothing);
    }
    let git = repo.git;
    let committed = git.show("HEAD", repo.document)?;
    let candidate = journal.candidate(system, &committed)?;
    let path = git.dir.join(repo.document);
    fs::write(&path, &candidate)?;
    if let Err(e) = eval.check(&path) {
        fs::write(&path, &committed)?;
        return Err(Error::Invalid(e));
    }
    let author = Person {
        name: by.name.clone(),
        id: by.id.clone(),
    };
    let before = git.head()?;
    let id = match git.commit(repo.document, &author, &message(text, by, &open)) {
        Ok(id) => id,
        Err(e) => {
            fs::write(&path, &committed)?;
            return Err(e.into());
        }
    };
    let ops = journal.committed(system, &id)?;
    let mut c = Committed {
        id,
        ops,
        outside,
        pushed: false,
    };
    if let Err(e) = record(&c) {
        journal.reopen(system, &c.id)?;
        git.run(&["reset", "--quiet", "--hard", &before])?;
        return Err(Error::Record(e));
    }
    c.pushed = push(repo).is_ok();
    Ok(c)
}

/// Push what the checkout has and the remote lacks (a commit whose push failed).
pub fn push(repo: &Repo) -> Result<(), Error> {
    if let Some((remote, branch)) = repo.remote {
        repo.git.push(remote, branch)?;
    }
    Ok(())
}

/// The operator's text, the operations, and a `Co-authored-by:` for every other operator.
fn message(text: &str, by: &Operator, ops: &[Op]) -> String {
    let mut m = text.trim().to_string();
    if m.is_empty() {
        m = format!("{} operations", ops.len());
    }
    m += "\n\nOperations:\n";
    for o in ops {
        m += &format!("  {} {} ({})\n", o.rev, o.summary(), o.by.name);
    }
    let mut others: Vec<String> = Vec::new();
    for o in ops.iter().filter(|o| o.by.id != by.id) {
        let line = format!("Co-authored-by: {} <{}>", o.by.name, o.by.id);
        if !others.contains(&line) {
            others.push(line);
        }
    }
    if let Some(last) = ops.last() {
        m += &format!("\nGolconda-Revision: {}\n", last.rev);
    }
    for line in others {
        m += &line;
        m.push('\n');
    }
    m
}

/// A document's options as the config of mkSystem would have the explicit ones: for an
/// evaluation that is no evaluation (tests, and the schema-only check).
pub fn explicit_config(text: &str) -> Result<Value, String> {
    let doc = to_json(text).map_err(|e| e.to_string())?;
    let mut config = Map::new();
    for (module, options) in doc.as_object().into_iter().flatten() {
        let mut o = Map::new();
        for (name, v) in options.as_object().into_iter().flatten() {
            o.insert(
                name.clone(),
                serde_json::json!({ "explicit": true, "value": v }),
            );
        }
        config.insert(module.clone(), Value::Object(o));
    }
    Ok(Value::Object(config))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate::{Edit, Request};
    use serde_json::json;

    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::process::Command;
    use tempfile::TempDir;

    /// Evaluation that reads the TOML; a document with `broken = true` in /system fails.
    struct Fake;
    impl Evaluate for Fake {
        fn config(&self, _: &Path, text: &str) -> Result<Value, String> {
            explicit_config(text)
        }
        fn check(&self, document: &Path) -> Result<(), String> {
            let text = fs::read_to_string(document).map_err(|e| e.to_string())?;
            if text.contains("broken = true") {
                Err("/system broken".into())
            } else {
                Ok(())
            }
        }
    }

    const DOC: &str = "[\"/system\"]\nname = \"s\"\n\n[\"/services/sshd\"]\nport = 22\n";

    struct Scene {
        _tmp: TempDir,
        dir: PathBuf,
        daemon: Git,
        other: PathBuf,
        allowed: PathBuf,
    }

    fn sh(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    /// A bare remote with the document on `main`, the daemon's clone, someone else's clone,
    /// and the daemon's signing key with an allowed-signers file for it.
    fn scene() -> Scene {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        sh(
            &dir,
            &["init", "--quiet", "--bare", "-b", "main", "remote.git"],
        );
        sh(&dir, &["clone", "--quiet", "remote.git", "seed"]);
        let seed = dir.join("seed");
        fs::write(seed.join("server.toml"), DOC).unwrap();
        sh(&seed, &["add", "server.toml"]);
        sh(
            &seed,
            &[
                "-c",
                "user.name=Seed",
                "-c",
                "user.email=seed@x",
                "commit",
                "-q",
                "-m",
                "seed",
            ],
        );
        sh(&seed, &["push", "-q", "origin", "HEAD:main"]);
        sh(&dir, &["clone", "--quiet", "remote.git", "daemon"]);
        sh(&dir, &["clone", "--quiet", "remote.git", "other"]);
        let key = dir.join("daemon-key");
        let st = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "golcondad", "-f"])
            .arg(&key)
            .status()
            .unwrap();
        assert!(st.success());
        let public = fs::read_to_string(key.with_extension("pub")).unwrap();
        let allowed = dir.join("allowed_signers");
        fs::write(
            &allowed,
            format!("golcondad@test namespaces=\"git\" {public}"),
        )
        .unwrap();
        Scene {
            _tmp: tmp,
            daemon: Git {
                dir: dir.join("daemon"),
                committer: Person {
                    name: "golcondad".into(),
                    id: "golcondad@test".into(),
                },
                signing_key: Some(key),
            },
            other: dir.join("other"),
            allowed,
            dir,
        }
    }

    fn who(n: &str) -> Operator {
        Operator {
            id: format!("{n}@example.com"),
            name: n[..1].to_uppercase() + &n[1..],
        }
    }

    fn set(j: &mut Journal, base: u64, path: &str, value: &str, by: &str) -> Result<Op, Refused> {
        let committed = DOC; // the schema check is empty here: any committed text will do
        j.apply(
            "s",
            committed,
            &json!({}),
            Request {
                base,
                module: "/services/sshd".into(),
                path: vec![path.into()],
                edit: Edit::Set(value.into()),
                by: who(by),
                via: "web".into(),
            },
        )
    }

    fn repo(s: &Scene) -> Repo<'_> {
        Repo {
            git: &s.daemon,
            document: Path::new("server.toml"),
            remote: Some(("origin", "main")),
        }
    }

    #[test]
    fn a_commit_holds_the_candidate_signed_by_the_daemon_and_is_pushed() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        set(&mut j, 0, "port", "2222", "alice").unwrap();
        set(&mut j, 1, "authorizedKeys", "[]", "bob").unwrap();
        let c = commit(&mut j, &repo(&s), &Fake, "s", &who("alice"), "sshd on 2222").unwrap();
        assert!(c.pushed);
        assert_eq!(c.ops.len(), 2);
        let text = fs::read_to_string(s.daemon.dir.join("server.toml")).unwrap();
        assert!(
            text.contains("port = 2222\nauthorizedKeys = []\n"),
            "{text}"
        );
        // author, committer, message
        let log = sh(
            &s.daemon.dir,
            &["log", "-1", "--format=%an <%ae>|%cn <%ce>|%B"],
        );
        let (authors, body) = log.split_at(log.find("|sshd").unwrap());
        assert_eq!(
            authors,
            "Alice <alice@example.com>|golcondad <golcondad@test>"
        );
        assert_eq!(
            body,
            "|sshd on 2222\n\nOperations:\n  1 set /services/sshd port 2222 (Alice)\n  \
             2 set /services/sshd authorizedKeys [] (Bob)\n\nGolconda-Revision: 2\n\
             Co-authored-by: Bob <bob@example.com>"
        );
        // the daemon's signature checks against its key
        let allowed = format!("gpg.ssh.allowedSignersFile={}", s.allowed.display());
        sh(&s.daemon.dir, &["-c", &allowed, "verify-commit", "HEAD"]);
        // the remote has it, and the journal says which commit holds the operations
        assert_eq!(sh(&s.dir.join("remote.git"), &["rev-parse", "main"]), c.id);
        assert_eq!(j.open_ops("s").unwrap(), Vec::<Op>::new());
        assert!(
            j.since("s", 0)
                .unwrap()
                .iter()
                .all(|o| o.commit.as_deref() == Some(c.id.as_str()))
        );
    }

    #[test]
    fn a_commit_whose_record_fails_is_undone_before_the_push() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        set(&mut j, 0, "port", "2222", "alice").unwrap();
        let head = s.daemon.head().unwrap();
        let e = commit_with(&mut j, &repo(&s), &Fake, "s", &who("alice"), "x", |c| {
            assert_eq!(c.ops.len(), 1);
            Err("the audit log is full".into())
        });
        assert!(matches!(e, Err(Error::Record(_))), "{e:?}");
        // the branch, the document, the remote and the journal as before
        assert_eq!(s.daemon.head().unwrap(), head);
        assert_eq!(
            std::fs::read_to_string(s.daemon.dir.join("server.toml")).unwrap(),
            DOC
        );
        assert_eq!(sh(&s.dir.join("remote.git"), &["rev-parse", "main"]), head);
        assert_eq!(j.open_ops("s").unwrap().len(), 1);
        assert!(j.open_ops("s").unwrap()[0].commit.is_none());
        // the hook says yes: committed and pushed
        let c = commit_with(
            &mut j,
            &repo(&s),
            &Fake,
            "s",
            &who("alice"),
            "x",
            |_| Ok(()),
        )
        .unwrap();
        assert!(c.pushed);
    }

    #[test]
    fn nothing_to_commit_and_a_candidate_that_does_not_check() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        assert!(matches!(
            commit(&mut j, &repo(&s), &Fake, "s", &who("alice"), "x"),
            Err(Error::Nothing)
        ));
        j.apply(
            "s",
            DOC,
            &json!({}),
            Request {
                base: 0,
                module: "/system".into(),
                path: vec!["broken".into()],
                edit: Edit::Set("true".into()),
                by: who("alice"),
                via: "web".into(),
            },
        )
        .unwrap();
        let head = s.daemon.head().unwrap();
        let e = commit(&mut j, &repo(&s), &Fake, "s", &who("alice"), "x");
        assert!(matches!(e, Err(Error::Invalid(_))), "{e:?}");
        // the document and the branch as they were, the operation still open
        assert_eq!(
            std::fs::read_to_string(s.daemon.dir.join("server.toml")).unwrap(),
            DOC
        );
        assert_eq!(s.daemon.head().unwrap(), head);
        assert_eq!(j.open_ops("s").unwrap().len(), 1);
    }

    /// Someone else commits `from` -> `to` in the document and pushes it.
    fn push_outside(s: &Scene, from: &str, to: &str) {
        sh(&s.other, &["pull", "-q", "origin", "main"]);
        let p = s.other.join("server.toml");
        let text = fs::read_to_string(&p).unwrap().replace(from, to);
        fs::write(&p, text).unwrap();
        sh(
            &s.other,
            &[
                "-c",
                "user.name=Carol",
                "-c",
                "user.email=carol@x",
                "commit",
                "-qam",
                "outside",
            ],
        );
        sh(&s.other, &["push", "-q", "origin", "HEAD:main"]);
    }

    #[test]
    fn an_outside_change_is_recorded_and_stops_a_commit_that_touches_it() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        set(&mut j, 0, "port", "2222", "alice").unwrap();
        push_outside(&s, "port = 22", "port = 2200");
        match commit(&mut j, &repo(&s), &Fake, "s", &who("alice"), "x") {
            Err(Error::Conflict { outside, yours }) => {
                assert_eq!(outside.len(), 1);
                assert_eq!(outside[0].summary(), "set /services/sshd port 2200");
                assert_eq!(outside[0].by.name, "Carol <carol@x>");
                assert_eq!(yours[0].summary(), "set /services/sshd port 2222");
            }
            other => panic!("{other:?}"),
        }
        // the checkout is the remote's now; the outside change has its revision
        let doc = fs::read_to_string(s.daemon.dir.join("server.toml")).unwrap();
        assert!(doc.contains("port = 2200"), "{doc}");
        assert_eq!(j.revision("s").unwrap(), 2);
    }

    #[test]
    fn an_outside_change_elsewhere_lets_the_commit_through_on_top_of_it() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        set(&mut j, 0, "port", "2222", "alice").unwrap();
        push_outside(&s, "name = \"s\"", "name = \"t\"");
        let c = commit(&mut j, &repo(&s), &Fake, "s", &who("alice"), "x").unwrap();
        assert_eq!(c.outside.len(), 1);
        assert!(c.pushed);
        let doc = fs::read_to_string(s.daemon.dir.join("server.toml")).unwrap();
        assert!(
            doc.contains("name = \"t\"") && doc.contains("port = 2222"),
            "{doc}"
        );
        // the commit is on top of Carol's
        assert_eq!(
            sh(&s.daemon.dir, &["log", "-1", "--format=%an", "HEAD~1"]),
            "Carol"
        );
    }

    #[test]
    fn a_push_that_fails_leaves_the_commit_local_and_a_later_push_sends_it() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        set(&mut j, 0, "port", "2222", "alice").unwrap();
        // the remote refuses every push for now
        let hook = s.dir.join("remote.git/hooks/pre-receive");
        fs::write(&hook, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
        let c = commit(&mut j, &repo(&s), &Fake, "s", &who("alice"), "x").unwrap();
        assert!(!c.pushed);
        assert_eq!(s.daemon.head().unwrap(), c.id);
        assert_eq!(j.open_ops("s").unwrap(), Vec::<Op>::new());
        // not pushed: the checkout is ahead of the remote, which is nothing new from outside
        assert_eq!(
            fetch(&mut j, &repo(&s), &Fake, "s").unwrap(),
            Vec::<Op>::new()
        );
        fs::remove_file(&hook).unwrap();
        push(&repo(&s)).unwrap();
        assert_eq!(sh(&s.dir.join("remote.git"), &["rev-parse", "main"]), c.id);
        // a fetch now sees nothing new: ours was ahead, not an outside change
        assert_eq!(
            fetch(&mut j, &repo(&s), &Fake, "s").unwrap(),
            Vec::<Op>::new()
        );
    }

    #[test]
    fn a_checkout_that_diverged_from_the_remote_is_refused() {
        let s = scene();
        let mut j = Journal::in_memory().unwrap();
        set(&mut j, 0, "port", "2222", "alice").unwrap();
        let local = Repo {
            remote: None,
            ..repo(&s)
        };
        commit(&mut j, &local, &Fake, "s", &who("alice"), "local only").unwrap();
        push_outside(&s, "name = \"s\"", "name = \"t\"");
        let e = fetch(&mut j, &repo(&s), &Fake, "s");
        assert!(matches!(e, Err(Error::Diverged(_))), "{e:?}");
    }

    #[test]
    fn explicit_config_reads_the_document() {
        assert_eq!(
            explicit_config(DOC).unwrap(),
            json!({ "/system": { "name": { "explicit": true, "value": "s" } },
                    "/services/sshd": { "port": { "explicit": true, "value": 22 } } })
        );
    }
}
