//! `golconda`: push a system's admin vars, and check, build and publish its releases.

use clap::{Args, CommandFactory, Parser, Subcommand};
use std::env::{self, consts};
use std::error;
use std::fmt::Write as _;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use vars::{Program, Remote, Store};

mod release;
mod vars;

/// Push a Golconda system's admin vars, and check, build and publish its releases.
///
/// git, gpgv, rclone, nix-build, ssh, ssh-keygen and age come from PATH, or GOLCONDA_<NAME>
/// (GOLCONDA_SSH="ssh -p 2222", GOLCONDA_SSH_KEYGEN).
#[derive(Parser)]
#[command(version, verbatim_doc_comment)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Admin vars: values a machine's image names but never contains, kept age-encrypted
    /// here and pushed over ssh
    #[command(subcommand)]
    Vars(Vars),
    /// Releases: the directory a build writes, which machines install from
    #[command(subcommand)]
    Release(Releases),
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
    /// version and DEST's) goes into the document, Nix builds mkImage's unsigned outputs, their
    /// signer signs them with the key set here, outside Nix, check checks the release, and one
    /// commit holds the version line with the release trailers. A failure puts the line back
    Build {
        /// The system's document, inside a Golconda checkout
        #[command(flatten)]
        doc: Doc,
        /// The key set (scripts/make-keys): Nix copies its public halves, the signer reads its
        /// private keys where they are
        #[arg(long, value_name = "DIR")]
        keys: PathBuf,
        /// The key set whose PCR key signs, when a db rotation keeps it (default: --keys)
        #[arg(long, value_name = "DIR")]
        pcr_keys: Option<PathBuf>,
        /// The key set whose release key signs SHA256SUMS, when a db rotation keeps it
        /// (default: --keys)
        #[arg(long, value_name = "DIR")]
        index_keys: Option<PathBuf>,
        /// The PKCS#11 module of the token that holds the db or PCR key, when a key set names
        /// it by URI (secureboot/db.pkcs11, pcr/pcr.pkcs11), e.g. a YubiKey's libykcs11.so
        #[arg(long, value_name = "FILE")]
        pkcs11_module: Option<PathBuf>,
        /// YYYYMMDD.N, or auto
        #[arg(long, value_name = "VERSION", default_value = "auto")]
        version: String,
        /// A destination whose versions count too
        #[arg(long, value_name = "DEST")]
        to: Option<String>,
        /// A new directory for the release: disk.raw, release/, and the link to the unsigned
        /// outputs
        #[arg(long, value_name = "DIR", default_value = "result-release")]
        out: PathBuf,
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
    /// Enrol HOST in its first boot: read its host key, show the fingerprint to compare with
    /// the console's line (or compare it with --fingerprint), sign it as a host certificate with
    /// ssh-keygen, store the certificate and the KRL, and push both (the KRL first)
    Enrol {
        #[command(flatten)]
        store: VarStore,
        /// The age identity that decrypts the stored vars (or GOLCONDA_AGE_IDENTITY)
        #[arg(short = 'i', long)]
        identity: Option<PathBuf>,
        host: String,
        /// The host CA's private key file; with --pkcs11-module its public key file (ca.pub),
        /// whose private half is on the token
        #[arg(long, value_name = "FILE")]
        ca_key: PathBuf,
        /// The PKCS#11 module of the token that holds the CA key (ssh-keygen -D), e.g. a
        /// YubiKey's libykcs11.so
        #[arg(long, value_name = "FILE")]
        pkcs11_module: Option<PathBuf>,
        /// A name clients reach HOST by (repeat it; default: HOST)
        #[arg(long = "principal", value_name = "NAME")]
        principals: Vec<String>,
        /// How long the certificate is valid, as ssh-keygen -V takes it
        #[arg(
            long,
            value_name = "INTERVAL",
            default_value = "-5m:+52w",
            allow_hyphen_values = true
        )]
        validity: String,
        /// The current KRL; without it, the one stored for HOST (enrol refuses when there is none)
        #[arg(long, value_name = "FILE")]
        krl: Option<PathBuf>,
        /// The fingerprint on HOST's console (SHA256:…): compare with it instead of asking
        #[arg(long, value_name = "SHA256:…")]
        fingerprint: Option<String>,
    },
}

#[derive(Args)]
struct VarStore {
    /// The age-encrypted admin vars, DIR/HOST/VAR/FILE.age
    #[arg(long = "vars", value_name = "DIR", default_value = "vars")]
    dir: PathBuf,
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
    let done = match cli.command {
        Command::Vars(v) => run_vars(v),
        Command::Release(r) => run_release(r),
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

/// `release build`: the version, the build, the check and the commit (release::build).
fn build_release(
    doc: &Doc,
    (keys, pcr_keys, index_keys): (&Path, Option<&Path>, Option<&Path>),
    pkcs11_module: Option<&Path>,
    version: &str,
    to: Option<&str>,
    out: PathBuf,
    (git, gpgv, rclone): (&Program, &Program, &Program),
) -> Result<String, Box<dyn error::Error>> {
    let version = match version {
        "auto" => None,
        v => Some(v.parse()?),
    };
    let dest = to.map(|to| release::Destination { rclone, to });
    let req = release::BuildRequest {
        document: &doc.file,
        system: &doc.system,
        keys,
        pcr_keys,
        index_keys,
        pkcs11_module,
        version,
        dest: dest.as_ref(),
        out,
        author: None,
    };
    let nix_build = Program::from_env("GOLCONDA_NIX_BUILD", "nix-build");
    let tools = release::Tools {
        nix_build: &nix_build,
        git,
        gpgv,
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
            pcr_keys,
            index_keys,
            pkcs11_module,
            version,
            to,
            out,
        } => build_release(
            &doc,
            (&keys, pcr_keys.as_deref(), index_keys.as_deref()),
            pkcs11_module.as_deref(),
            &version,
            to.as_deref(),
            out,
            (&git, &gpgv, &rclone),
        ),
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

/// `-i`, or GOLCONDA_AGE_IDENTITY; without either a usage error (2). An empty variable names none.
fn age_identity(given: Option<PathBuf>, command: &str) -> PathBuf {
    given
        .or_else(|| {
            env::var_os("GOLCONDA_AGE_IDENTITY")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .unwrap_or_else(|| {
            Cli::command()
                .error(
                    clap::error::ErrorKind::MissingRequiredArgument,
                    format!("vars {command} needs -i IDENTITY (or GOLCONDA_AGE_IDENTITY)"),
                )
                .exit()
        })
}

/// The lines `sealed ID` and `restarted UNIT` of a push.
fn pushed(p: &vars::Pushed) -> String {
    let mut out = String::new();
    for id in &p.sealed {
        out.push_str(&format!("sealed {id}\n"));
    }
    for unit in &p.restarted {
        out.push_str(&format!("restarted {unit}\n"));
    }
    out
}

/// The operator's check: the fingerprint, and a line on standard input that says yes.
fn ask(host: &str, line: &str) -> bool {
    eprintln!("{host}'s host key: {line}");
    eprint!(
        "Is this the fingerprint on {host}'s console or journal (golconda: ssh host key …)? \
         Type yes to sign it: "
    );
    let mut answer = String::new();
    io::stdin().read_line(&mut answer).is_ok() && answer.trim() == "yes"
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
            let identity = age_identity(identity, "push");
            pushed(&vars::push(
                &store(s),
                &identity,
                &remote(&host)?,
                &host,
                &only,
            )?)
        }
        Vars::Enrol {
            store: s,
            identity: id,
            host,
            ca_key,
            pkcs11_module,
            principals,
            validity,
            krl,
            fingerprint,
        } => {
            let id = age_identity(id, "enrol");
            if ca_key.to_string_lossy().starts_with("pkcs11:") {
                return Err(
                    "ssh-keygen finds a token's key by its public half, not by a URI: \
                     give --ca-key CA.pub and --pkcs11-module MODULE \
                     (ssh-keygen -D MODULE lists the token's keys)"
                        .into(),
                );
            }
            let krl = krl
                .map(|f| fs::read(&f).map_err(|e| format!("{}: {e}", f.display())))
                .transpose()?;
            let signer = vars::Signer {
                keygen: Program::from_env("GOLCONDA_SSH_KEYGEN", "ssh-keygen"),
                ca: ca_key,
                module: pkcs11_module,
            };
            let req = vars::Enrol {
                host: &host,
                principals: &principals,
                validity: &validity,
                krl: krl.as_deref(),
                fingerprint: fingerprint.as_deref(),
            };
            let e = vars::enrol(
                &store(s),
                &id,
                &remote(&host)?,
                &signer,
                &req,
                &mut |line| ask(&host, line),
            )?;
            let mut out = format!("host key {}\n", e.fingerprint);
            for p in &e.stored {
                out.push_str(&format!("stored {}\n", p.display()));
            }
            out + &pushed(&e.pushed)
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
