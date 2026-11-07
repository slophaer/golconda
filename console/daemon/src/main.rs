//! `golcondad`: the console daemon.

use clap::Parser;
use golconda_core::advisories::{self, Advisories};
use golconda_core::machine::Patience;
use golconda_core::upstream::Upstream;
use golconda_core::vars::Program;
use golcondad::app::{App, Identity, Level, Signin};
use golcondad::auth::{Oidc, OidcConfig};
use golcondad::jobs::{JobConfig, Runner};
use std::env;
use std::fs;
use std::net::SocketAddr;
use std::path::{self, PathBuf};
use std::process::ExitCode;
use std::sync;
use std::time;

/// Golconda's console daemon: the systems' configuration as web pages and JSON.
#[derive(Parser, Debug)]
#[command(
    version,
    after_help = "Sign-in is either OIDC (--oidc-issuer, --oidc-client-id, --public-url) or, \
                  for development, --dev-identity. iets comes from PATH, or GOLCONDA_IETS."
)]
pub struct Args {
    /// Where to listen
    #[arg(long, default_value = "127.0.0.1:8796")]
    listen: SocketAddr,
    /// A system and its TOML document; repeat for more
    #[arg(long = "system", value_name = "NAME=DOCUMENT", required = true, value_parser = system)]
    systems: Vec<(String, PathBuf)>,
    /// Everyone is NAME at LEVEL (operator or read-only), for development: only on a
    /// loopback address
    #[arg(long = "dev-identity", value_name = "NAME:LEVEL", value_parser = identity)]
    identity: Option<Identity>,
    /// The OIDC provider people sign in with (https)
    #[arg(long, value_name = "URL", conflicts_with = "identity", requires_all = ["oidc_client_id", "public_url"])]
    oidc_issuer: Option<String>,
    /// This daemon's client id at the provider
    #[arg(long, value_name = "ID")]
    oidc_client_id: Option<String>,
    /// A file with the client secret, for a provider that wants one
    #[arg(long, value_name = "FILE")]
    oidc_client_secret_file: Option<PathBuf>,
    /// PEM certificates the provider's TLS certificate must chain to (our own CA's); without
    /// it, the public roots built in
    #[arg(long, value_name = "FILE")]
    oidc_ca_file: Option<PathBuf>,
    /// The public client the CLI and TUI sign in with through the device flow; their ID tokens
    /// must be meant for it. Without it, no bearer token is taken
    #[arg(long, value_name = "ID", requires = "oidc_issuer")]
    oidc_cli_client_id: Option<String>,
    /// Where browsers reach this daemon, such as https://console.example.com: the redirect
    /// address and the one host name it answers to
    #[arg(long, value_name = "URL")]
    public_url: Option<String>,
    /// The group (in the token's groups claim) whose members are operators
    #[arg(long, value_name = "GROUP", default_value = "golconda-operators")]
    operator_group: String,
    /// The group whose members may only read
    #[arg(long, value_name = "GROUP", default_value = "golconda-readers")]
    read_only_group: String,
    /// The whole daemon shows state and changes nothing
    #[arg(long)]
    read_only: bool,
    /// Where the daemon keeps its journal (journal.db) and audit log (audit/); without it,
    /// it only reads
    #[arg(long, value_name = "DIR")]
    state: Option<PathBuf>,
    /// The SSH private key the daemon signs configuration commits and audit entries with
    #[arg(long, value_name = "FILE", requires = "state")]
    signing_key: Option<PathBuf>,
    /// The remote each system's checkout fetches from and pushes to, on its current branch
    #[arg(long, value_name = "REMOTE", requires = "state")]
    push: Option<String>,
    /// The remote the audit repository is pushed to (a branch that refuses force-pushes)
    #[arg(long, value_name = "REMOTE", requires = "state")]
    audit_push: Option<String>,
    /// How often to fetch the systems' remote, in seconds, for changes made elsewhere
    #[arg(long, value_name = "SECONDS", default_value_t = 300)]
    fetch_every: u64,
    /// The key set deploys sign releases with (scripts/make-keys); without it, no deploy
    #[arg(long, value_name = "DIR", requires = "state")]
    release_keys: Option<PathBuf>,
    /// Copy the release key set into the store for the build: for a build daemon with a chroot
    /// store, which sees no path outside it
    #[arg(long, requires = "release_keys")]
    release_copy_keys: bool,
    /// The OSV server the packages' known vulnerabilities come from
    #[arg(long, value_name = "URL", default_value = advisories::OSV_URL)]
    osv_url: String,
    /// How long an OSV answer is kept before the package is asked about again, in seconds
    #[arg(long, value_name = "SECONDS", default_value_t = advisories::LIFETIME.as_secs())]
    osv_every: u64,
    /// Never ask OSV (the Packages page then shows no vulnerabilities)
    #[arg(long, conflicts_with = "osv_url")]
    no_osv: bool,
    /// A tree of `sources.toml` files uptrack is run on for the packages' newest upstream
    /// versions (a repkgs checkout; Golconda's `packages/`); repeat for more. Needs
    /// GOLCONDA_UPTRACK, uptrack and its leading arguments
    #[arg(long = "uptrack-tree", value_name = "DIR")]
    uptrack_trees: Vec<PathBuf>,
    /// How long an uptrack answer is kept before it is asked for again, in seconds
    #[arg(long, value_name = "SECONDS", default_value_t = advisories::LIFETIME.as_secs())]
    uptrack_every: u64,
    /// How long a job waits for a machine to come back blessed after a reboot, in seconds
    #[arg(long, value_name = "SECONDS", default_value_t = 900)]
    confirm_timeout: u64,
}

fn system(v: &str) -> Result<(String, PathBuf), String> {
    let (n, d) = v.split_once('=').ok_or("takes NAME=DOCUMENT")?;
    if n.is_empty()
        || !n
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(format!("{n:?} is not a name (letters, digits, - and _)"));
    }
    Ok((n.to_string(), PathBuf::from(d)))
}

fn identity(v: &str) -> Result<Identity, String> {
    let (n, l) = v.split_once(':').ok_or("takes NAME:LEVEL")?;
    let level = match l {
        "operator" => Level::Operator,
        "read-only" => Level::ReadOnly,
        _ => return Err(format!("no level {l:?} (operator, read-only)")),
    };
    Ok(Identity {
        id: format!("dev:{n}"),
        name: n.to_string(),
        level,
    })
}

/// How people sign in, as the arguments say.
#[derive(Debug)]
enum Mode {
    Dev(Identity),
    Oidc(OidcConfig),
}

/// What clap cannot check: one document per name; one way to sign in; the development
/// identity on loopback only; a public URL with a scheme.
fn check(mut a: Args) -> Result<(Args, Mode), String> {
    // git runs in other directories (the audit repository, each checkout): paths are absolute
    let abs = |p: &PathBuf| path::absolute(p).map_err(|e| format!("{}: {e}", p.display()));
    if let Some(p) = &a.signing_key {
        a.signing_key = Some(abs(p)?);
    }
    if let Some(p) = &a.release_keys {
        a.release_keys = Some(abs(p)?);
    }
    if let Some(p) = &a.state {
        a.state = Some(abs(p)?);
    }
    for (i, (n, _)) in a.systems.iter().enumerate() {
        if a.systems[..i].iter().any(|(m, _)| m == n) {
            return Err(format!("--system: {n} is given twice"));
        }
    }
    if let Some(identity) = a.identity.clone() {
        if !a.listen.ip().is_loopback() {
            return Err(format!(
                "--dev-identity signs everyone in: it listens on a loopback address only, not {}",
                a.listen
            ));
        }
        return Ok((a, Mode::Dev(identity)));
    }
    let Some(issuer) = a.oidc_issuer.clone() else {
        return Err("give a way to sign in: --oidc-issuer, or --dev-identity".into());
    };
    let public_url = a.public_url.clone().unwrap_or_default();
    if !public_url.starts_with("https://") && !public_url.starts_with("http://") {
        return Err(format!("--public-url {public_url:?} is not an http(s) URL"));
    }
    let client_secret = match &a.oidc_client_secret_file {
        Some(f) => Some(
            fs::read_to_string(f)
                .map_err(|e| format!("--oidc-client-secret-file {}: {e}", f.display()))?
                .trim()
                .to_string(),
        ),
        None => None,
    };
    let ca_pem = match &a.oidc_ca_file {
        Some(f) => Some(
            fs::read_to_string(f).map_err(|e| format!("--oidc-ca-file {}: {e}", f.display()))?,
        ),
        None => None,
    };
    let config = OidcConfig {
        issuer,
        client_id: a.oidc_client_id.clone().unwrap_or_default(),
        client_secret,
        public_url,
        operator_group: a.operator_group.clone(),
        read_only_group: a.read_only_group.clone(),
        ca_pem,
        cli_client_id: a.oidc_cli_client_id.clone(),
    };
    Ok((a, Mode::Oidc(config)))
}

/// The programs jobs run (each from PATH or its GOLCONDA_ variable) and their settings.
fn job_config(a: &Args) -> JobConfig {
    let p = Program::from_env;
    JobConfig {
        ssh: p("GOLCONDA_SSH", "ssh"),
        nix_build: p("GOLCONDA_NIX_BUILD", "nix-build"),
        gpgv: p("GOLCONDA_GPGV", "gpgv"),
        rclone: p("GOLCONDA_RCLONE", "rclone"),
        release_keys: a.release_keys.clone(),
        copy_keys: a.release_copy_keys,
        patience: Patience {
            every: time::Duration::from_secs(5),
            until: time::Duration::from_secs(a.confirm_timeout),
        },
    }
}

/// OSV, unless `--no-osv`; with `--state` its answers are kept in `STATE/advisories.json`.
fn advisories(a: &Args) -> Option<Advisories> {
    (!a.no_osv).then(|| {
        Advisories::open(
            &a.osv_url,
            a.state.as_ref().map(|s| s.join("advisories.json")),
            time::Duration::from_secs(a.osv_every),
        )
    })
}

/// uptrack, when it is set up: the program from `GOLCONDA_UPTRACK` and at least one tree.
fn upstream(a: &Args, program: Option<Program>) -> Result<Option<sync::Arc<Upstream>>, String> {
    match (program, a.uptrack_trees.is_empty()) {
        (None, true) => Ok(None),
        (None, false) => {
            Err("--uptrack-tree needs GOLCONDA_UPTRACK: uptrack, and its leading arguments".into())
        }
        (Some(_), true) => {
            Err("GOLCONDA_UPTRACK is set, but there is no --uptrack-tree to run it on".into())
        }
        (Some(program), false) => Ok(Some(Upstream::open(
            program,
            a.uptrack_trees.clone(),
            a.state.as_ref().map(|s| s.join("upstream.json")),
            time::Duration::from_secs(a.uptrack_every),
        ))),
    }
}

/// The app with what it looks up on the network: OSV, and uptrack when it is set up.
fn with_lookups(mut app: App, a: &Args) -> Result<App, String> {
    let program = env::var_os("GOLCONDA_UPTRACK")
        .filter(|v| !v.is_empty())
        .map(|_| Program::from_env("GOLCONDA_UPTRACK", "uptrack"));
    if let Some(osv) = advisories(a) {
        app = app.with_advisories(osv);
    }
    if let Some(uptrack) = upstream(a, program)? {
        app = app.with_upstream(uptrack);
    }
    Ok(app)
}

/// Changes made elsewhere: fetched on a timer (and before every commit), when the checkouts
/// have a remote.
fn fetch_on_a_timer(app: &sync::Arc<App>, fetch_every: u64) {
    if app.writes.as_ref().is_some_and(|w| w.push.is_some()) {
        // changes made elsewhere: fetched on a timer and before every commit
        let (a2, every) = (app.clone(), time::Duration::from_secs(fetch_every.max(10)));
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(every).await;
                let a3 = a2.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    golcondad::write::fetch_all(&a3, a3.writes.as_ref().expect("checked"));
                })
                .await;
            }
        });
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    // clap answers --help and --version, and exits 2 on a usage error
    let (a, mode) = match check(Args::parse()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("golcondad: {e}");
            return ExitCode::from(2);
        }
    };
    let listener = match tokio::net::TcpListener::bind(a.listen).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("golcondad: cannot listen on {}: {e}", a.listen);
            return ExitCode::from(1);
        }
    };
    let (signin, who) = match mode {
        Mode::Dev(i) => {
            let who = format!("everyone as {} ({})", i.name, i.level.name());
            (Signin::Dev(i), who)
        }
        Mode::Oidc(config) => {
            let who = format!("sign-in through {}", config.issuer);
            match tokio::task::spawn_blocking(move || Oidc::discover(config)).await {
                Ok(Ok(o)) => (Signin::Oidc(Box::new(o)), who),
                Ok(Err(e)) => {
                    eprintln!("golcondad: OIDC: {e}");
                    return ExitCode::from(1);
                }
                Err(e) => panic!("{e}"),
            }
        }
    };
    eprintln!(
        "golcondad: http://{}, {who}{}, {} system(s), fonts: {}",
        a.listen,
        if a.read_only { ", read-only" } else { "" },
        a.systems.len(),
        if golcondad::FONTS.is_empty() {
            "the system's"
        } else {
            "IBM Plex"
        },
    );
    let jobs = job_config(&a);
    let mut app = App::new(a.systems.clone(), signin, a.read_only);
    app = match with_lookups(app, &a) {
        Ok(app) => app,
        Err(e) => {
            eprintln!("golcondad: {e}");
            return ExitCode::from(2);
        }
    };
    if let Some(state) = &a.state {
        let host = fs::read_to_string("/proc/sys/kernel/hostname")
            .map_or_else(|_| "localhost".into(), |h| h.trim().to_string());
        let committer = golconda_core::git::Person {
            name: "golcondad".into(),
            id: format!("golcondad@{host}"),
        };
        match golcondad::write::Writes::open(
            state,
            committer,
            a.signing_key.clone(),
            a.push.clone(),
            a.audit_push.clone(),
        ) {
            Ok(w) => app = app.with_writes(w),
            Err(e) => {
                eprintln!("golcondad: --state: {e}");
                return ExitCode::from(1);
            }
        }
        match Runner::open(state, jobs) {
            Ok(r) => app = app.with_jobs(r),
            Err(e) => {
                eprintln!("golcondad: --state: the job store: {e}");
                return ExitCode::from(1);
            }
        }
    }
    let app = sync::Arc::new(app);
    fetch_on_a_timer(&app, a.fetch_every);
    let app = golcondad::app::router_shared(app);
    let served = axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await;
    match served {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("golcondad: {e}");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;
    use std::iter;

    fn args(s: &str) -> Result<(Args, Mode), String> {
        Args::try_parse_from(iter::once("golcondad").chain(s.split_whitespace()))
            .map_err(|e| e.to_string())
            .and_then(check)
    }

    fn level(m: Mode) -> Level {
        match m {
            Mode::Dev(i) => i.level,
            Mode::Oidc(_) => panic!("not the development identity"),
        }
    }

    #[test]
    fn a_development_identity_on_loopback() {
        let (a, m) = args("--system server=s.toml --dev-identity alice:operator").unwrap();
        assert_eq!(a.listen.to_string(), "127.0.0.1:8796");
        assert_eq!(level(m), Level::Operator);
        let (a, m) =
            args("--listen [::1]:9000 --system a=x --dev-identity bob:read-only --read-only")
                .unwrap();
        assert!(a.read_only);
        assert_eq!(level(m), Level::ReadOnly);
    }

    #[test]
    fn oidc_listens_anywhere() {
        let (_, m) = args(
            "--listen 0.0.0.0:443 --system s=x --oidc-issuer https://idp.example \
             --oidc-client-id console --public-url https://console.example",
        )
        .unwrap();
        let Mode::Oidc(c) = m else { panic!("OIDC") };
        assert_eq!(c.issuer, "https://idp.example");
        assert_eq!(c.operator_group, "golconda-operators");
        assert_eq!(c.read_only_group, "golconda-readers");
        assert_eq!(c.client_secret, None);
    }

    #[test]
    fn paths_are_absolute_where_git_runs_elsewhere() {
        // git signs in the audit repository's directory: a relative key would not be found
        let (a, _) =
            args("--system s=x --dev-identity a:operator --state st --signing-key key").unwrap();
        assert!(a.signing_key.as_ref().unwrap().is_absolute());
        assert!(a.state.as_ref().unwrap().is_absolute());
        assert!(a.signing_key.unwrap().ends_with("key"));
    }

    #[test]
    fn osv_is_asked_every_six_hours_unless_told_not_to() {
        let (a, _) = args("--system s=x --dev-identity a:operator").unwrap();
        assert_eq!(a.osv_url, "https://api.osv.dev");
        assert_eq!(a.osv_every, 21600);
        assert!(!a.no_osv);
        let (a, _) = args(
            "--system s=x --dev-identity a:operator --osv-url http://127.0.0.1:9 --osv-every 60",
        )
        .unwrap();
        assert_eq!(
            (a.osv_url.as_str(), a.osv_every),
            ("http://127.0.0.1:9", 60)
        );
        let (a, _) = args("--system s=x --dev-identity a:operator --no-osv").unwrap();
        assert!(a.no_osv);
        assert!(
            args("--system s=x --dev-identity a:operator --no-osv --osv-url http://x")
                .unwrap_err()
                .contains("cannot be used with")
        );
    }

    #[test]
    fn uptrack_needs_its_program_and_a_tree() {
        let plain = |s: &str| args(s).unwrap().0;
        let program = || Some(Program::new(vec!["uptrack".into()]));
        let none = plain("--system s=x --dev-identity a:operator");
        assert_eq!(none.uptrack_every, 21600);
        assert!(upstream(&none, None).unwrap().is_none());
        let e = upstream(&none, program()).err().unwrap();
        assert!(e.contains("--uptrack-tree"), "{e}");
        let trees =
            plain("--system s=x --dev-identity a:operator --uptrack-tree /a --uptrack-tree /b");
        assert_eq!(
            trees.uptrack_trees,
            [PathBuf::from("/a"), PathBuf::from("/b")]
        );
        let e = upstream(&trees, None).err().unwrap();
        assert!(e.contains("GOLCONDA_UPTRACK"), "{e}");
        assert!(upstream(&trees, program()).unwrap().is_some());
    }

    #[test]
    fn the_command_line_is_consistent() {
        Args::command().debug_assert();
    }

    #[test]
    fn refused() {
        let e = |s| args(s).unwrap_err();
        assert!(e("--system s=x").contains("--oidc-issuer, or --dev-identity"));
        // one way to sign in
        assert!(
            e(
                "--system s=x --dev-identity a:operator --oidc-issuer https://i \
                   --oidc-client-id c --public-url https://p"
            )
            .contains("cannot be used with")
        );
        // OIDC needs its client id and the public URL
        assert!(
            e("--system s=x --oidc-issuer https://i --public-url https://p")
                .contains("--oidc-client-id")
        );
        assert!(
            e("--system s=x --oidc-issuer https://i --oidc-client-id c").contains("--public-url")
        );
        assert!(
            e("--system s=x --oidc-issuer https://i --oidc-client-id c --public-url p.example")
                .contains("not an http(s) URL")
        );
        assert!(
            e("--listen 0.0.0.0:8796 --system s=x --dev-identity a:operator").contains("loopback")
        );
        assert!(
            e("--listen 192.0.2.1:80 --system s=x --dev-identity a:operator").contains("loopback")
        );
        assert!(e("--dev-identity a:operator").contains("--system"));
        assert!(e("--system s=x --dev-identity a:root").contains("no level"));
        assert!(e("--system ../x=y --dev-identity a:operator").contains("not a name"));
        assert!(e("--system a=x --system a=y --dev-identity a:operator").contains("twice"));
    }
}
