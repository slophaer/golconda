//! `golcondad`: the console daemon.

use clap::Parser;
use golcondad::app::{App, Identity, Level, router};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;

/// Golconda's console daemon: the systems' configuration as web pages and JSON.
#[derive(Parser, Debug)]
#[command(
    version,
    after_help = "Sign-in (OIDC) is not there yet: without --dev-identity golcondad does not \
                  start. iets comes from PATH, or GOLCONDA_IETS."
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
        name: n.to_string(),
        level,
    })
}

/// What clap cannot check: one document per name, an identity, loopback.
fn check(a: Args) -> Result<(Args, Identity), String> {
    for (i, (n, _)) in a.systems.iter().enumerate() {
        if a.systems[..i].iter().any(|(m, _)| m == n) {
            return Err(format!("--system: {n} is given twice"));
        }
    }
    let Some(identity) = a.identity.clone() else {
        return Err("sign-in (OIDC) is not there yet: give --dev-identity".into());
    };
    if !a.listen.ip().is_loopback() {
        return Err(format!(
            "--dev-identity signs everyone in: it listens on a loopback address only, not {}",
            a.listen
        ));
    }
    Ok((a, identity))
}

#[tokio::main]
async fn main() -> ExitCode {
    // clap answers --help and --version, and exits 2 on a usage error
    let (a, identity) = match check(Args::parse()) {
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
    eprintln!(
        "golcondad: http://{} as {} ({}){}, {} system(s), fonts: {}",
        a.listen,
        identity.name,
        identity.level.name(),
        if a.read_only { ", read-only" } else { "" },
        a.systems.len(),
        if golcondad::FONTS.is_empty() {
            "the system's"
        } else {
            "IBM Plex"
        },
    );
    let app = router(App::new(a.systems, identity, a.read_only));
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

    fn args(s: &str) -> Result<(Args, Identity), String> {
        Args::try_parse_from(std::iter::once("golcondad").chain(s.split_whitespace()))
            .map_err(|e| e.to_string())
            .and_then(check)
    }

    #[test]
    fn a_development_identity_on_loopback() {
        let (a, i) = args("--system server=s.toml --dev-identity alice:operator").unwrap();
        assert_eq!(a.listen.to_string(), "127.0.0.1:8796");
        assert_eq!(i.level, Level::Operator);
        let (a, i) =
            args("--listen [::1]:9000 --system a=x --dev-identity bob:read-only --read-only")
                .unwrap();
        assert!(a.read_only);
        assert_eq!(i.level, Level::ReadOnly);
    }

    #[test]
    fn the_command_line_is_consistent() {
        use clap::CommandFactory;
        Args::command().debug_assert();
    }

    #[test]
    fn refused() {
        let e = |s| args(s).unwrap_err();
        assert!(e("--system s=x").contains("OIDC"));
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
