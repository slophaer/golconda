//! `golcondad`: the console daemon.

use clap::Parser;
use golcondad::app::{App, Identity, Level, Signin, router};
use golcondad::auth::{Oidc, OidcConfig};
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;

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
fn check(a: Args) -> Result<(Args, Mode), String> {
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
    };
    Ok((a, Mode::Oidc(config)))
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
    let app = router(App::new(a.systems, signin, a.read_only));
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
