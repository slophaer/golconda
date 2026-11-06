//! The git program, run on the daemon's checkout: fetch, fast-forward, commit, sign, push.
//!
//! A program rather than a library, as iets, age and ssh are: the daemon's git is the one
//! operators know, and SSH signing (`gpg.format = ssh`) is git calling ssh-keygen. Every run
//! leaves the user's and the system's git configuration out, so the daemon behaves the same on
//! every host and in the tests.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, thiserror::Error)]
#[error("git {args}: {message}")]
pub struct Error {
    pub args: String,
    pub message: String,
}

/// A person in a commit: `Name <id>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Person {
    pub name: String,
    /// the OIDC subject, or an e-mail address
    pub id: String,
}

impl Person {
    pub fn line(&self) -> String {
        format!("{} <{}>", self.name, self.id)
    }
}

/// A checkout and how the daemon commits in it.
pub struct Git {
    pub dir: PathBuf,
    /// the committer: the daemon
    pub committer: Person,
    /// the SSH private key commits are signed with; none: unsigned (tests, development)
    pub signing_key: Option<PathBuf>,
}

impl Git {
    fn command(&self) -> Command {
        let mut c = Command::new("git");
        c.current_dir(&self.dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("LC_ALL", "C")
            .env("GIT_COMMITTER_NAME", &self.committer.name)
            .env("GIT_COMMITTER_EMAIL", &self.committer.id)
            .stdin(Stdio::null());
        c
    }

    /// Run git with `args`; its standard output, trimmed.
    pub fn run(&self, args: &[&str]) -> Result<String, Error> {
        let out = self.command().args(args).output().map_err(|e| Error {
            args: args.join(" "),
            message: e.to_string(),
        })?;
        if !out.status.success() {
            return Err(Error {
                args: args.join(" "),
                message: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    pub fn head(&self) -> Result<String, Error> {
        self.run(&["rev-parse", "HEAD"])
    }

    /// The text of `path` (relative to the checkout) at `rev`.
    pub fn show(&self, rev: &str, path: &Path) -> Result<String, Error> {
        let spec = format!("{rev}:{}", path.display());
        let out = self
            .command()
            .args(["show", &spec])
            .output()
            .map_err(|e| Error {
                args: format!("show {spec}"),
                message: e.to_string(),
            })?;
        if !out.status.success() {
            return Err(Error {
                args: format!("show {spec}"),
                message: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// `a` is `b` or an ancestor of it.
    pub fn is_ancestor(&self, a: &str, b: &str) -> Result<bool, Error> {
        let st = self
            .command()
            .args(["merge-base", "--is-ancestor", a, b])
            .status()
            .map_err(|e| Error {
                args: "merge-base".into(),
                message: e.to_string(),
            })?;
        Ok(st.success())
    }

    /// Fetch `branch` from `remote`: the commit it is at there.
    pub fn fetch(&self, remote: &str, branch: &str) -> Result<String, Error> {
        self.run(&["fetch", "--quiet", remote, branch])?;
        self.run(&["rev-parse", "FETCH_HEAD"])
    }

    /// The authors of the commits after `from` up to `to`, oldest first.
    pub fn authors(&self, from: &str, to: &str) -> Result<Vec<Person>, Error> {
        let out = self.run(&[
            "log",
            "--reverse",
            "--format=%an%x00%ae",
            &format!("{from}..{to}"),
        ])?;
        Ok(out
            .lines()
            .filter_map(|l| l.split_once('\0'))
            .map(|(n, e)| Person {
                name: n.into(),
                id: e.into(),
            })
            .collect())
    }

    /// Commit `path` with `message`, `author` as the author, the daemon as the committer, signed
    /// when there is a key. The new commit's id.
    pub fn commit(&self, path: &Path, author: &Person, message: &str) -> Result<String, Error> {
        let p = path.to_string_lossy();
        self.run(&["add", "--", &p])?;
        let author = author.line();
        let mut args: Vec<String> = Vec::new();
        if let Some(key) = &self.signing_key {
            args.extend([
                "-c".into(),
                "gpg.format=ssh".into(),
                "-c".into(),
                format!("user.signingkey={}", key.display()),
            ]);
        }
        args.extend(["commit".into(), "--quiet".into(), "--no-verify".into()]);
        if self.signing_key.is_some() {
            args.push("-S".into());
        }
        args.extend([
            format!("--author={author}"),
            "-m".into(),
            message.into(),
            "--".into(),
            p.into_owned(),
        ]);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run(&args)?;
        self.head()
    }

    pub fn push(&self, remote: &str, branch: &str) -> Result<(), Error> {
        self.run(&[
            "push",
            "--quiet",
            remote,
            &format!("HEAD:refs/heads/{branch}"),
        ])
        .map(drop)
    }
}
