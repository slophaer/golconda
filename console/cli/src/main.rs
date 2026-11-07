//! `golconda`: read, explain and change a Golconda system's configuration, and push its
//! admin vars.

use clap::{Args, CommandFactory, Parser, Subcommand};
use golconda_core::audit;
use golconda_core::check;
use golconda_core::diff::{Change, against_git, diff};
use golconda_core::document::{self, parse_path, parse_value};
use golconda_core::eval::Iets;
use golconda_core::git::{Git, Person};
use golconda_core::release;
use golconda_core::system::System;
use golconda_core::vars::{self, Program, Remote, Store};
use std::env::{self, consts};
use std::error;
use std::fmt::Write as _;
use std::io::{self, Read};
use std::path::{self, Path, PathBuf};
use std::process::ExitCode;

mod login;

/// Read, explain and change a Golconda system's configuration.
///
/// OPTION is a TOML dotted key below the module (networks.lan.network.DNS, networks."lan.1").
/// VALUE is TOML (22, "22", [1, 2], { a = 1 }); text that is not TOML is a string; a value
/// that starts with a dash and is not a number goes after `--`. set and delete write only
/// when the result passes the schema and evaluates; comments and layout stay. iets, ssh,
/// age and gpgv come from PATH, or GOLCONDA_<NAME> (GOLCONDA_SSH="ssh -p 2222").
#[derive(Parser)]
#[command(version, verbatim_doc_comment)]
struct Cli {
    /// A golcondad to work through (its candidate) instead of the file: config set, delete,
    /// candidate, commit and discard go there
    #[arg(long, global = true, value_name = "URL")]
    server: Option<String>,
    /// The system's name on that daemon
    #[arg(long, global = true, value_name = "NAME", default_value = "server")]
    name: String,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Show, explain, set, delete or validate options
    #[command(subcommand)]
    Config(Config),
    /// The set and delete operations from another revision's (or document's) effective
    /// configuration to FILE's, defaults included
    Diff {
        #[command(flatten)]
        doc: Doc,
        /// JSON instead of text
        #[arg(long)]
        json: bool,
        /// Against this document instead of a git revision
        #[arg(long, value_name = "OTHER", conflicts_with = "rev")]
        from: Option<PathBuf>,
        /// The git revision to compare with
        #[arg(default_value = "HEAD")]
        rev: String,
    },
    /// Admin vars: values a machine's image names but never contains, kept age-encrypted
    /// here and pushed over ssh
    #[command(subcommand)]
    Vars(Vars),
    /// The audit log: a git repository with one signed entry per commit
    #[command(subcommand)]
    Audit(Audit),
    /// Releases: the directory a build writes, which machines install from
    #[command(subcommand)]
    Release(Releases),
    /// Sign in to the daemon --server names, through its OIDC provider's device flow: open the
    /// address it prints and confirm the code. The tokens stay in
    /// $XDG_STATE_HOME/golconda/tokens.json
    Login,
    /// Forget the tokens for the daemon --server names
    Logout,
}

#[derive(Subcommand)]
enum Releases {
    /// Check a release directory: SHA256SUMS has the four files in their fixed order with
    /// matching digests, the names carry one image id and version and the root hash's UUIDs,
    /// and SHA256SUMS.gpg is a signature by the key set's release key
    Check {
        /// The release directory (a build's release/)
        dir: PathBuf,
        /// The key set (scripts/make-keys): its release/index.pgp is the key machines trust
        #[arg(long, value_name = "DIR")]
        keys: PathBuf,
        /// JSON instead of text
        #[arg(long)]
        json: bool,
    },
    /// Check a release directory, then upload it to DEST: refused when DEST serves a newer or
    /// the same version, or when the release commit records other digests (or there is none).
    /// The files go first, the signature and the index last; nothing is deleted
    Publish {
        /// The release directory
        dir: PathBuf,
        /// Where machines fetch from: a directory, or remote:path of rclone's (S3, SFTP, …)
        #[arg(long, value_name = "DEST")]
        to: String,
        /// The key set: its release/index.pgp must have signed the index
        #[arg(long, value_name = "DIR")]
        keys: PathBuf,
        /// The configuration repository with the release commits
        #[arg(long, value_name = "DIR", default_value = ".")]
        repo: PathBuf,
        /// Publish a release no release commit records (one built by hand)
        #[arg(long)]
        unrecorded: bool,
    },
    /// Build a release from a clean tree: the version (auto: today's date, after the document's
    /// version and DEST's) goes into the document, mkImage builds it, check checks it, and one
    /// commit holds the version line with the release trailers. A failure puts the line back
    Build {
        /// The system's document, inside a Golconda checkout
        #[command(flatten)]
        doc: Doc,
        /// The key set (scripts/make-keys)
        #[arg(long, value_name = "DIR")]
        keys: PathBuf,
        /// YYYYMMDD.N, or auto
        #[arg(long, value_name = "VERSION", default_value = "auto")]
        version: String,
        /// A destination whose versions count too
        #[arg(long, value_name = "DEST")]
        to: Option<String>,
        /// Pass the key set as a path, copied into the store: for a build daemon with a chroot
        /// store, which sees no path outside it
        #[arg(long)]
        copy_keys: bool,
        /// Where to link the build's output
        #[arg(long, value_name = "PATH", default_value = "result-release")]
        out_link: PathBuf,
    },
    /// The release commits, newest first; with --to also what DEST holds and serves
    List {
        /// Only this image
        #[arg(long, value_name = "ID")]
        image: Option<String>,
        /// A destination to compare with
        #[arg(long, value_name = "DEST")]
        to: Option<String>,
        /// The configuration repository
        #[arg(long, value_name = "DIR", default_value = ".")]
        repo: PathBuf,
    },
}

#[derive(Subcommand)]
enum Audit {
    /// Check every commit: signed by an allowed key, one entry added, nothing removed
    Verify {
        /// A clone of the audit repository
        #[arg(long, value_name = "DIR")]
        repo: PathBuf,
        /// The signers git accepts (gpg.ssh.allowedSignersFile): the daemon's key, or its CA
        /// as cert-authority
        #[arg(long, value_name = "FILE")]
        allowed_signers: PathBuf,
    },
}

#[derive(Subcommand)]
enum Vars {
    /// Store a value, read from stdin, age-encrypted to the keys in DIR/recipients.txt
    Set {
        #[command(flatten)]
        store: VarStore,
        host: String,
        var: String,
        file: String,
    },
    /// Push every admin var HOST declares (or only the VARs named), and restart their units
    Push {
        #[command(flatten)]
        store: VarStore,
        /// The age identity that decrypts them (or GOLCONDA_AGE_IDENTITY)
        #[arg(short = 'i', long)]
        identity: Option<PathBuf>,
        host: String,
        vars: Vec<String>,
    },
    /// Per file: stored here? sealed there?
    List {
        #[command(flatten)]
        store: VarStore,
        host: String,
    },
    /// Print a local var's public file, such as the host key a CA signs
    Pub {
        host: String,
        var: String,
        file: String,
    },
}

#[derive(Args)]
struct VarStore {
    /// The age-encrypted admin vars, DIR/HOST/VAR/FILE.age
    #[arg(long = "vars", value_name = "DIR", default_value = "vars")]
    dir: PathBuf,
}

#[derive(Subcommand)]
enum Config {
    /// Every option with its value, defaults marked
    Show {
        #[command(flatten)]
        doc: Doc,
        /// Only what the document sets
        #[arg(long)]
        set: bool,
        /// JSON instead of text
        #[arg(long)]
        json: bool,
    },
    /// What an option is, its value, and where it is declared and set
    Explain {
        #[command(flatten)]
        doc: Doc,
        /// JSON instead of text
        #[arg(long)]
        json: bool,
        module: String,
        option: String,
    },
    /// Set an option (or, without OPTION, a module's whole table)
    #[command(
        allow_negative_numbers = true,
        override_usage = "golconda config set [OPTIONS] <MODULE> [OPTION] <VALUE>"
    )]
    Set {
        #[command(flatten)]
        doc: Doc,
        /// With --server: the revision the change is on (default: the candidate's now)
        #[arg(long)]
        base: Option<u64>,
        module: String,
        /// The option (a TOML dotted key), then the value (TOML, or else a string)
        #[arg(num_args = 1..=2, required = true, value_name = "[OPTION] VALUE")]
        operands: Vec<String>,
    },
    /// Delete an option (or, without OPTION, the module)
    Delete {
        #[command(flatten)]
        doc: Doc,
        /// With --server: the revision the change is on (default: the candidate's now)
        #[arg(long)]
        base: Option<u64>,
        module: String,
        option: Option<String>,
    },
    /// With --server: the candidate's revision and its operations not yet committed
    Candidate,
    /// With --server: commit the candidate (signed, pushed)
    Commit {
        /// What the commit is for
        #[arg(short = 'm', long)]
        message: String,
    },
    /// With --server: drop the candidate's operations not yet committed
    Discard,
    /// Check the document: the schema, then evaluation
    Validate {
        #[command(flatten)]
        doc: Doc,
    },
}

#[derive(Args)]
struct Doc {
    /// The system's document
    #[arg(short = 'f', long = "file", default_value = "server.toml")]
    file: PathBuf,
    /// The Nix system to evaluate for
    #[arg(long, default_value_t = format!("{}-linux", consts::ARCH))]
    system: String,
}

fn main() -> ExitCode {
    // usage errors exit 2 (clap's)
    let cli = Cli::parse();
    let done = match (cli.server, cli.command) {
        (Some(url), Command::Login) => login::login(&url, &mut io::stderr()),
        (Some(url), Command::Logout) => login::logout(&url).map(|had| {
            if had {
                format!("signed out of {url}\n")
            } else {
                format!("not signed in to {url}\n")
            }
        }),
        (None, Command::Login | Command::Logout) => Cli::command()
            .error(
                clap::error::ErrorKind::MissingRequiredArgument,
                "login and logout are for a daemon: give --server",
            )
            .exit(),
        (Some(url), command) => remote::through(&url, &cli.name, command),
        (None, command) => run(command),
    };
    match done {
        Ok(out) => {
            print!("{out}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("golconda: {e}");
            ExitCode::from(1)
        }
    }
}

/// An option path (a TOML dotted key), empty for the module itself.
fn path(option: Option<&String>) -> Result<Vec<String>, document::EditError> {
    option.map_or(Ok(Vec::new()), |o| parse_path(o))
}

fn run_diff(
    iets: &Iets,
    doc: &Doc,
    json: bool,
    from: Option<PathBuf>,
    rev: &str,
) -> Result<String, Box<dyn error::Error>> {
    let changes = match from {
        Some(other) => {
            let before = System::load(iets, &other, &doc.system)?;
            let after = System::load(iets, &doc.file, &doc.system)?;
            diff(&before.config, &after.config)
        }
        None => against_git(iets, &doc.file, rev, &doc.system)?.1,
    };
    Ok(if json {
        let v: Vec<_> = changes.iter().map(Change::to_json).collect();
        format!("{:#}\n", serde_json::Value::Array(v))
    } else {
        changes.iter().map(|c| c.to_text() + "\n").collect()
    })
}

fn verify_audit(repo: PathBuf, allowed_signers: &Path) -> Result<String, Box<dyn error::Error>> {
    let git = Git {
        dir: repo,
        committer: Person {
            name: "golconda".into(),
            id: "golconda".into(),
        },
        signing_key: None,
    };
    // git runs in the repository: a relative file would be looked for there
    let allowed = path::absolute(allowed_signers)?;
    let n = audit::Audit { git: &git }.verify(&allowed)?;
    Ok(format!("{n} entries, each one signed line\n"))
}

/// candidate, commit and discard without --server: a usage error, there is no candidate
fn needs_server(c: &Config) -> ! {
    let name = match c {
        Config::Candidate => "candidate",
        Config::Commit { .. } => "commit",
        _ => "discard",
    };
    Cli::command()
        .error(
            clap::error::ErrorKind::MissingRequiredArgument,
            format!("config {name} works on a daemon's candidate: give --server"),
        )
        .exit()
}

/// One line per release commit, marked when DEST holds or serves it; and what DEST serves
/// that no release commit here records.
fn list_releases(
    git: &Program,
    rclone: &Program,
    image: Option<&str>,
    to: Option<&str>,
    repo: &Path,
) -> Result<String, Box<dyn error::Error>> {
    let recs = release::records(git, repo, image, None)?;
    let dest = to.map(|to| release::Destination { rclone, to });
    let (files, served) = match &dest {
        Some(d) => (d.files()?, d.index()?.map(|(_, i)| (i.id, i.version))),
        None => (Vec::new(), None),
    };
    let mut out = String::new();
    for r in &recs {
        let at = if served.as_ref() == Some(&(r.id.clone(), r.version)) {
            "  served"
        } else if release::versions_in(&files, &r.id).contains(&r.version) {
            "  at the destination"
        } else {
            ""
        };
        let _ = writeln!(out, "{} {}  {}{at}", r.id, r.version, &r.commit[..12]);
    }
    if let (Some(d), Some((id, v))) = (&dest, &served)
        && !recs.iter().any(|r| (&r.id, r.version) == (id, *v))
    {
        let _ = writeln!(out, "{} serves {id} {v}: no release commit here", d.to);
    }
    Ok(out)
}

fn run_release(command: Releases) -> Result<String, Box<dyn error::Error>> {
    let gpgv = Program::from_env("GOLCONDA_GPGV", "gpgv");
    let git = Program::from_env("GOLCONDA_GIT", "git");
    let rclone = Program::from_env("GOLCONDA_RCLONE", "rclone");
    match command {
        Releases::Publish {
            dir,
            to,
            keys,
            repo,
            unrecorded,
        } => {
            let r = release::check(&dir, &release::keyring(&keys), &gpgv)?;
            let dest = release::Destination {
                rclone: &rclone,
                to: &to,
            };
            let (id, v) = (&r.index.id, r.index.version);
            Ok(
                match release::publish(&r, &dest, &git, &repo, unrecorded)? {
                    release::Published::AlreadyThere => {
                        format!("{to} serves {id} {v} already: nothing to upload\n")
                    }
                    release::Published::Uploaded { record: Some(c) } => {
                        format!("{id} {v} published to {to} (release commit {})\n", c.commit)
                    }
                    release::Published::Uploaded { record: None } => {
                        format!("{id} {v} published to {to}, unrecorded\n")
                    }
                },
            )
        }
        Releases::Build {
            doc,
            keys,
            version,
            to,
            copy_keys,
            out_link,
        } => {
            let version = match version.as_str() {
                "auto" => None,
                v => Some(v.parse()?),
            };
            let dest = to.as_deref().map(|to| release::Destination {
                rclone: &rclone,
                to,
            });
            let req = release::BuildRequest {
                document: &doc.file,
                system: &doc.system,
                keys: &keys,
                copy_keys,
                version,
                dest: dest.as_ref(),
                out_link,
            };
            let nix_build = Program::from_env("GOLCONDA_NIX_BUILD", "nix-build");
            let tools = release::Tools {
                nix_build: &nix_build,
                git: &git,
                gpgv: &gpgv,
            };
            let b = release::build(&req, &tools)?;
            Ok(format!(
                "{} {} built: {}\nrelease commit {}\n",
                b.record.id,
                b.record.version,
                b.release.dir.display(),
                b.record.commit
            ))
        }
        Releases::List { image, to, repo } => {
            list_releases(&git, &rclone, image.as_deref(), to.as_deref(), &repo)
        }
        Releases::Check { dir, keys, json } => {
            let r = release::check(&dir, &release::keyring(&keys), &gpgv)?;
            let i = &r.index;
            Ok(if json {
                let files: Vec<_> = i
                    .files
                    .iter()
                    .map(|f| serde_json::json!({ "name": f.name, "sha256": f.digest }))
                    .collect();
                format!(
                    "{:#}\n",
                    serde_json::json!({
                        "id": i.id,
                        "version": i.version.to_string(),
                        "rootHash": r.root_hash,
                        "files": files,
                    })
                )
            } else {
                format!(
                    "{} {}: 4 files match SHA256SUMS, signed by the release key\n",
                    i.id, i.version
                )
            })
        }
    }
}

fn run(command: Command) -> Result<String, Box<dyn error::Error>> {
    let iets = Iets::from_env();
    let config = match command {
        Command::Diff {
            doc,
            json,
            from,
            rev,
        } => return run_diff(&iets, &doc, json, from, &rev),
        Command::Config(c @ (Config::Candidate | Config::Commit { .. } | Config::Discard)) => {
            needs_server(&c)
        }
        Command::Config(c) => c,
        Command::Vars(v) => return run_vars(v),
        Command::Release(r) => return run_release(r),
        Command::Login | Command::Logout => unreachable!("main takes them"),
        Command::Audit(Audit::Verify {
            repo,
            allowed_signers,
        }) => return verify_audit(repo, &allowed_signers),
    };
    Ok(match config {
        Config::Validate { doc } => {
            check::validate(&iets, &doc.file, &doc.system)?;
            format!("{}: valid\n", doc.file.display())
        }
        Config::Set {
            doc,
            module,
            operands,
            ..
        } => {
            let (value, option) = operands.split_last().expect("clap: 1 or 2 operands");
            let p = path(option.first())?;
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            check::apply(&iets, &doc.file, &doc.system, |text| {
                document::set(text, &module, &p, parse_value(value))
            })?;
            String::new()
        }
        Config::Delete {
            doc,
            module,
            option,
            ..
        } => {
            let p = path(option.as_ref())?;
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            check::apply(&iets, &doc.file, &doc.system, |text| {
                document::delete(text, &module, &p)
            })?;
            String::new()
        }
        Config::Candidate | Config::Commit { .. } | Config::Discard => unreachable!("above"),
        Config::Show { doc, set, json } => {
            let sys = System::load(&iets, &doc.file, &doc.system)?;
            if !json {
                return Ok(sys.show(set));
            }
            let mut config = sys.config;
            if set {
                for options in config
                    .as_object_mut()
                    .into_iter()
                    .flat_map(|m| m.values_mut())
                {
                    if let Some(o) = options.as_object_mut() {
                        o.retain(|_, v| v["explicit"] == true);
                    }
                }
                if let Some(m) = config.as_object_mut() {
                    m.retain(|_, o| o.as_object().is_some_and(|o| !o.is_empty()));
                }
            }
            format!("{config:#}\n")
        }
        Config::Explain {
            doc,
            json,
            module,
            option,
        } => {
            let sys = System::load(&iets, &doc.file, &doc.system)?;
            let p = path(Some(&option))?;
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            let e = sys.explain(&module, &p)?;
            if json {
                format!("{:#}\n", e.to_json())
            } else {
                e.to_text()
            }
        }
    })
}

/// The config commands through a golcondad (--server): its JSON routes.
mod remote {
    use super::{Command, Config, login, run};
    use serde_json::{Value, json};
    use std::{error, result};

    type Result<T> = result::Result<T, Box<dyn error::Error>>;

    struct Daemon {
        url: String,
        name: String,
        agent: ureq::Agent,
        /// the ID token from golconda login, when it signed in there
        bearer: Option<String>,
    }

    impl Daemon {
        fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<(u16, Value)> {
            let url = format!(
                "{}/systems/{}/{path}",
                self.url.trim_end_matches('/'),
                self.name
            );
            let auth = self
                .bearer
                .as_ref()
                .map(|t| format!("Bearer {t}"))
                .unwrap_or_default();
            let res = match body {
                None => {
                    let mut r = self.agent.get(&url).header("Accept", "application/json");
                    if !auth.is_empty() {
                        r = r.header("Authorization", &auth);
                    }
                    r.call()
                }
                Some(b) => {
                    let mut r = self
                        .agent
                        .post(&url)
                        .header("Accept", "application/json")
                        .header("Content-Type", "application/json");
                    if !auth.is_empty() {
                        r = r.header("Authorization", &auth);
                    }
                    r.send(b.to_string())
                }
            }
            .map_err(|e| format!("{method} {url}: {e}"))?;
            let status = res.status().as_u16();
            let text = res.into_body().read_to_string().unwrap_or_default();
            Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
        }

        fn revision(&self) -> Result<u64> {
            let v = answer(self.call("GET", "candidate", None)?)?;
            Ok(v["revision"].as_u64().unwrap_or(0))
        }
    }

    /// The answer's JSON when it is 200; else what the daemon said, as an error.
    fn answer((status, v): (u16, Value)) -> Result<Value> {
        match status {
            200 => Ok(v),
            401 => Err(format!(
                "the daemon wants a sign-in: golconda login --server URL ({})",
                v["error"].as_str().unwrap_or("")
            )
            .into()),
            409 => {
                let theirs: Vec<String> = v["theirs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|o| {
                        format!(
                            "rev {} {} by {} at {}",
                            o["rev"],
                            summary(o),
                            o["by"]["name"].as_str().unwrap_or("?"),
                            o["at"].as_str().unwrap_or("?")
                        )
                    })
                    .collect();
                Err(format!("conflict: {}", theirs.join("; ")).into())
            }
            422 => {
                let p: Vec<String> = v["problems"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|p| {
                        let path = p["path"].as_str().unwrap_or("");
                        let m = p["message"].as_str().unwrap_or("");
                        if path.is_empty() {
                            m.to_string()
                        } else {
                            format!("{path}: {m}")
                        }
                    })
                    .collect();
                Err(p.join("\n").into())
            }
            s => Err(format!("{s}: {}", v["error"].as_str().unwrap_or("no answer")).into()),
        }
    }

    /// `set /services/sshd port 2222`, from an operation's JSON.
    fn summary(o: &Value) -> String {
        let path: Vec<&str> = o["path"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        let at = golconda_core::document::path_name(o["module"].as_str().unwrap_or("?"), &path);
        match o["op"].as_str() {
            Some("set") => format!("set {at} {}", o["value"].as_str().unwrap_or("")),
            _ => format!("delete {at}"),
        }
    }

    pub fn through(url: &str, name: &str, command: Command) -> Result<String> {
        let agent = login::agent()?;
        let d = Daemon {
            url: url.into(),
            name: name.into(),
            bearer: login::bearer(&agent, url)?,
            agent,
        };
        let op = |base: Option<u64>,
                  module: String,
                  option: Option<&String>,
                  op: &str,
                  value: Option<&String>|
         -> Result<String> {
            let base = match base {
                Some(b) => b,
                None => d.revision()?,
            };
            let mut body = json!({ "base": base, "module": module, "option": option.map_or("", String::as_str), "op": op });
            if let Some(v) = value {
                body["value"] = Value::String(v.clone());
            }
            let o = answer(d.call("POST", "ops", Some(body))?)?;
            Ok(format!("rev {}: {}\n", o["rev"], summary(&o)))
        };
        match command {
            Command::Config(Config::Set {
                base,
                module,
                operands,
                ..
            }) => {
                let (value, option) = operands.split_last().expect("clap: 1 or 2 operands");
                op(base, module, option.first(), "set", Some(value))
            }
            Command::Config(Config::Delete {
                base,
                module,
                option,
                ..
            }) => op(base, module, option.as_ref(), "delete", None),
            Command::Config(Config::Candidate) => {
                let v = answer(d.call("GET", "candidate", None)?)?;
                let mut out = format!("revision {}\n", v["revision"]);
                for o in v["ops"].as_array().into_iter().flatten() {
                    out += &format!(
                        "  {} {} ({})\n",
                        o["rev"],
                        summary(o),
                        o["by"]["name"].as_str().unwrap_or("?")
                    );
                }
                Ok(out)
            }
            Command::Config(Config::Commit { message }) => {
                let v = answer(d.call("POST", "commit", Some(json!({ "message": message })))?)?;
                let pushed = if v["pushed"] == true {
                    "pushed"
                } else {
                    "not pushed yet"
                };
                Ok(format!(
                    "committed {}, {pushed}\n",
                    v["commit"].as_str().unwrap_or("?")
                ))
            }
            Command::Config(Config::Discard) => {
                let v = answer(d.call("POST", "discard", Some(json!({})))?)?;
                Ok(format!(
                    "discarded {} operations\n",
                    v["discarded"].as_array().map_or(0, Vec::len)
                ))
            }
            // everything else reads the file, daemon or not
            other => run(other),
        }
    }
}

fn run_vars(command: Vars) -> Result<String, Box<dyn error::Error>> {
    let store = |s: VarStore| Store::new(&s.dir, Program::from_env("GOLCONDA_AGE", "age"));
    let remote = |host: &str| Remote::new(Program::from_env("GOLCONDA_SSH", "ssh"), host);
    Ok(match command {
        Vars::Set {
            store: s,
            host,
            var,
            file,
        } => {
            let mut value = Vec::new();
            io::stdin().read_to_end(&mut value)?;
            let path = store(s).set(&host, &var, &file, &value)?;
            format!("stored {}\n", path.display())
        }
        Vars::Push {
            store: s,
            identity,
            host,
            vars: only,
        } => {
            // an empty GOLCONDA_AGE_IDENTITY names none; without one it is a usage error (2)
            let identity = identity
                .or_else(|| {
                    env::var_os("GOLCONDA_AGE_IDENTITY")
                        .filter(|v| !v.is_empty())
                        .map(PathBuf::from)
                })
                .unwrap_or_else(|| {
                    Cli::command()
                        .error(
                            clap::error::ErrorKind::MissingRequiredArgument,
                            "vars push needs -i IDENTITY (or GOLCONDA_AGE_IDENTITY)",
                        )
                        .exit()
                });
            let p = vars::push(&store(s), &identity, &remote(&host)?, &host, &only)?;
            let mut out = String::new();
            for id in &p.sealed {
                out.push_str(&format!("sealed {id}\n"));
            }
            for unit in &p.restarted {
                out.push_str(&format!("restarted {unit}\n"));
            }
            out
        }
        Vars::List { store: s, host } => vars::list(&store(s), &remote(&host)?, &host)?,
        Vars::Pub { host, var, file } => String::from_utf8(remote(&host)?.public(&var, &file)?)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_line_is_consistent() {
        Cli::command().debug_assert();
    }
}
