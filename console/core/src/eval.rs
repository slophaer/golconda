//! Evaluation through the `iets` binary, one process per evaluation.
//!
//! A subprocess, not the iets library: a crash or a runaway evaluation ends the child, not the
//! caller, and the contract is JSON, not iets' Rust API (docs: console/README.md).

use serde_json::Value;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fmt, io, path};

/// An argument of the evaluated function.
pub enum Arg<'a> {
    /// `--argstr name value`
    Str(&'a str, &'a str),
    /// `--arg name /abs/path`: a path value, read under pure evaluation's rules
    Path(&'a str, &'a Path),
}

/// The `iets` program to run.
pub struct Iets {
    program: OsString,
}

/// An evaluation error, from iets' `internal-json` record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvalError {
    /// the message without the trace
    pub message: String,
    pub file: Option<String>,
    pub line: Option<u64>,
    pub column: Option<u64>,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("cannot run {program}: {1}", program = .0.to_string_lossy())]
    Spawn(OsString, io::Error),
    #[error("evaluation failed: {0}")]
    Eval(EvalError),
    /// iets succeeded but its output is not JSON
    #[error("iets printed no JSON: {0}")]
    Output(String),
}

impl fmt::Display for EvalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (&self.file, self.line, self.column) {
            (Some(file), Some(l), Some(c)) => write!(f, "{file}:{l}:{c}: ")?,
            (Some(file), Some(l), None) => write!(f, "{file}:{l}: ")?,
            (Some(file), None, _) => write!(f, "{file}: ")?,
            _ => {}
        }
        f.write_str(&self.message)
    }
}

impl Iets {
    pub fn new(program: impl Into<OsString>) -> Self {
        Iets {
            program: program.into(),
        }
    }

    /// `GOLCONDA_IETS`, or `iets` from PATH.
    pub fn from_env() -> Self {
        Iets::new(env::var_os("GOLCONDA_IETS").unwrap_or_else(|| "iets".into()))
    }

    /// Evaluate the function `expr` with `args`, in `dir`, strictly, to JSON.
    ///
    /// `dir` is the evaluation's root: pure evaluation reads files under it only, and its
    /// `iets.toml` sets the lints.
    pub fn eval_json(&self, dir: &Path, expr: &str, args: &[Arg]) -> Result<Value, Error> {
        let mut cmd = Command::new(&self.program);
        cmd.current_dir(dir).args([
            "eval",
            "--json",
            "--strict",
            "--log-format",
            "internal-json",
        ]);
        let mut paths = false;
        for a in args {
            match a {
                Arg::Str(n, v) => {
                    cmd.args(["--argstr", n, v]);
                }
                Arg::Path(n, p) => {
                    paths = true;
                    cmd.args(["--arg", n]).arg(absolute(p));
                }
            }
        }
        if paths {
            // the path arguments are absolute on purpose; the lint is for files
            cmd.args(["--lint", "absolute-path-literal=off"]);
        }
        cmd.args(["--expr", expr]);
        let out = cmd
            .output()
            .map_err(|e| Error::Spawn(self.program.clone(), e))?;
        if !out.status.success() {
            let mut e = parse_error(&String::from_utf8_lossy(&out.stderr));
            // a file of the checkout by its path there
            let root = absolute(dir);
            let rel = (e.file.as_deref())
                .and_then(|f| Path::new(f).strip_prefix(&root).ok())
                .map(|r| r.display().to_string());
            if rel.is_some() {
                e.file = rel;
            }
            return Err(Error::Eval(e));
        }
        serde_json::from_slice(&out.stdout).map_err(|e| Error::Output(e.to_string()))
    }
}

fn absolute(p: &Path) -> PathBuf {
    path::absolute(p).unwrap_or_else(|_| p.to_path_buf())
}

/// The first error record on iets' stderr; the last non-empty line when there is none.
pub fn parse_error(stderr: &str) -> EvalError {
    for line in stderr.lines() {
        let Some(json) = line.strip_prefix("@nix ") else {
            continue;
        };
        let Ok(r) = serde_json::from_str::<Value>(json) else {
            continue;
        };
        if r["action"] != "msg" || r["level"] != 0 {
            continue;
        }
        let message = if let Some(m) = r["raw_msg"].as_str() {
            m.to_string()
        } else {
            let m = r["msg"].as_str().unwrap_or("");
            let first = m.lines().next().unwrap_or("");
            first.strip_prefix("error: ").unwrap_or(first).to_string()
        };
        let line_no = r["line"].as_u64();
        let column = r["column"].as_u64();
        // `file` is "path:line:column"; keep the path
        let file = r["file"].as_str().map(|f| {
            let suffix = match (line_no, column) {
                (Some(l), Some(c)) => format!(":{l}:{c}"),
                (Some(l), None) => format!(":{l}"),
                _ => String::new(),
            };
            f.strip_suffix(&suffix).unwrap_or(f).to_string()
        });
        return EvalError {
            message,
            file,
            line: line_no,
            column,
        };
    }
    EvalError {
        message: stderr
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("iets failed with no message")
            .to_string(),
        file: None,
        line: None,
        column: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_error_record_gives_message_and_position() {
        let stderr = concat!(
            r#"@nix {"action":"start","id":1,"level":4,"text":"evaluating"}"#,
            "\n",
            // a warning is not the error
            r#"@nix {"action":"msg","code":"lint","level":1,"msg":"warning: [dir-copy-flake] x","raw_msg":"[dir-copy-flake] x"}"#,
            "\n",
            r#"@nix {"action":"msg","code":"throw","column":30,"file":"/s/adios/default.nix:51:30","level":0,"line":51,"msg":"error: while computing /services/sshd args: in option 'port': Expected type 'int'\n       at /s/adios/default.nix:51:30\n       … while calling"}"#,
            "\n",
        );
        assert_eq!(
            parse_error(stderr),
            EvalError {
                message:
                    "while computing /services/sshd args: in option 'port': Expected type 'int'"
                        .into(),
                file: Some("/s/adios/default.nix".into()),
                line: Some(51),
                column: Some(30),
            }
        );
    }

    #[test]
    fn raw_msg_is_the_message_when_there_is_one() {
        let e = parse_error(
            r#"@nix {"action":"msg","code":"lint","level":0,"msg":"error: [x] y\n at z","raw_msg":"[x] y"}"#,
        );
        assert_eq!(e.message, "[x] y");
        assert_eq!(e.file, None);
    }

    #[test]
    fn without_a_record_the_last_line_is_the_message() {
        let e = parse_error("something\nunknown flag --x\n\n");
        assert_eq!(e.message, "unknown flag --x");
    }

    #[test]
    fn display_puts_the_position_first() {
        let e = EvalError {
            message: "boom".into(),
            file: Some("a.nix".into()),
            line: Some(3),
            column: Some(4),
        };
        assert_eq!(e.to_string(), "a.nix:3:4: boom");
    }
}
