//! `golcondad --listen ADDR --system NAME=DOCUMENT... --dev-identity NAME:LEVEL [--read-only]`

use golcondad::app::{App, Identity, Level, router};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: golcondad [--listen ADDR] --system NAME=DOCUMENT... \
--dev-identity NAME:LEVEL [--read-only]

  --listen ADDR             where to listen (default: 127.0.0.1:8796)
  --system NAME=DOCUMENT    a system and its TOML document; repeat for more
  --dev-identity NAME:LEVEL everyone is NAME at LEVEL (operator or read-only), for
                            development: only on a loopback address
  --read-only               the whole daemon shows state and changes nothing

Sign-in (OIDC) is not there yet: without --dev-identity golcondad does not start.
iets comes from PATH, or GOLCONDA_IETS.";

#[derive(Debug)]
pub struct Args {
    listen: SocketAddr,
    systems: Vec<(String, PathBuf)>,
    identity: Identity,
    read_only: bool,
}

fn parse(argv: &[String]) -> Result<Args, String> {
    let mut listen: SocketAddr = "127.0.0.1:8796".parse().unwrap();
    let mut systems = Vec::new();
    let mut identity = None;
    let mut read_only = false;
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        let mut value = || it.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--listen" => listen = value()?.parse().map_err(|e| format!("--listen: {e}"))?,
            "--system" => {
                let v = value()?;
                let (n, d) = v.split_once('=').ok_or("--system takes NAME=DOCUMENT")?;
                if n.is_empty()
                    || !n
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
                {
                    return Err(format!(
                        "--system: {n:?} is not a name (letters, digits, - and _)"
                    ));
                }
                systems.push((n.to_string(), PathBuf::from(d)));
            }
            "--dev-identity" => {
                let v = value()?;
                let (n, l) = v.split_once(':').ok_or("--dev-identity takes NAME:LEVEL")?;
                let level = match l {
                    "operator" => Level::Operator,
                    "read-only" => Level::ReadOnly,
                    _ => {
                        return Err(format!(
                            "--dev-identity: no level {l:?} (operator, read-only)"
                        ));
                    }
                };
                identity = Some(Identity {
                    name: n.to_string(),
                    level,
                });
            }
            "--read-only" => read_only = true,
            a => return Err(format!("unknown argument {a}")),
        }
    }
    if systems.is_empty() {
        return Err("give at least one --system".into());
    }
    let Some(identity) = identity else {
        return Err("sign-in (OIDC) is not there yet: give --dev-identity".into());
    };
    if !listen.ip().is_loopback() {
        return Err(format!(
            "--dev-identity signs everyone in: it listens on a loopback address only, not {listen}"
        ));
    }
    Ok(Args {
        listen,
        systems,
        identity,
        read_only,
    })
}

#[tokio::main]
async fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match argv.first().map(String::as_str) {
        Some("--version") => {
            println!("golcondad {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Some("--help" | "-h") => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        _ => {}
    }
    let a = match parse(&argv) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("golcondad: {e}\n{USAGE}");
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
        a.identity.name,
        a.identity.level.name(),
        if a.read_only { ", read-only" } else { "" },
        a.systems.len(),
        if golcondad::FONTS.is_empty() {
            "the system's"
        } else {
            "IBM Plex"
        },
    );
    let app = router(App::new(a.systems, a.identity, a.read_only));
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

    fn args(s: &str) -> Result<Args, String> {
        parse(&s.split_whitespace().map(str::to_string).collect::<Vec<_>>())
    }

    #[test]
    fn a_development_identity_on_loopback() {
        let a = args("--system server=s.toml --dev-identity alice:operator").unwrap();
        assert_eq!(a.listen.to_string(), "127.0.0.1:8796");
        assert_eq!(a.identity.level, Level::Operator);
        let a = args("--listen [::1]:9000 --system a=x --dev-identity bob:read-only --read-only")
            .unwrap();
        assert!(a.read_only);
        assert_eq!(a.identity.level, Level::ReadOnly);
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
    }
}
