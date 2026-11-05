//! `golconda`: read and explain a Golconda system's configuration.

use golconda_core::eval::Iets;
use golconda_core::system::System;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage:
  golconda --version | --help
  golconda config show [--set] [--json] [-f FILE] [--system SYSTEM]
  golconda config explain [--json] [-f FILE] [--system SYSTEM] MODULE OPTION

  -f FILE          the system's document (default: server.toml)
  --system SYSTEM  the Nix system to evaluate for (default: this machine's)
  --set            only what the document sets
  --json           JSON instead of text

iets comes from PATH, or GOLCONDA_IETS.";

struct Args {
    command: String,
    file: PathBuf,
    system: String,
    set_only: bool,
    json: bool,
    rest: Vec<String>,
}

fn parse(argv: &[String]) -> Result<Args, String> {
    let mut it = argv.iter();
    if it.next().map(String::as_str) != Some("config") {
        return Err("give a command".into());
    }
    let command = it.next().cloned().unwrap_or_default();
    if command != "show" && command != "explain" {
        return Err(format!("unknown command config {command}"));
    }
    let mut a = Args {
        command,
        file: "server.toml".into(),
        system: format!("{}-linux", std::env::consts::ARCH),
        set_only: false,
        json: false,
        rest: Vec::new(),
    };
    while let Some(arg) = it.next() {
        let mut value = || it.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "-f" | "--file" => a.file = value()?.into(),
            "--system" => a.system = value()?,
            "--set" if a.command == "show" => a.set_only = true,
            "--json" => a.json = true,
            f if f.starts_with("--") || (f.starts_with('-') && f.len() > 1) => {
                return Err(format!("unknown flag {f}"));
            }
            _ => a.rest.push(arg.clone()),
        }
    }
    let operands = if a.command == "explain" { 2 } else { 0 };
    if a.rest.len() != operands {
        return Err(format!("config {} takes {operands} operands", a.command));
    }
    Ok(a)
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match argv.first().map(String::as_str) {
        Some("--version") => {
            println!("golconda {}", env!("CARGO_PKG_VERSION"));
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
            eprintln!("golconda: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(&a) {
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

fn run(a: &Args) -> Result<String, Box<dyn std::error::Error>> {
    let sys = System::load(&Iets::from_env(), &a.file, &a.system)?;
    Ok(match a.command.as_str() {
        "show" if a.json => {
            let mut config = sys.config.clone();
            if a.set_only {
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
        "show" => sys.show(a.set_only),
        _ => {
            let e = sys.explain(&a.rest[0], &a.rest[1])?;
            if a.json {
                format!("{:#}\n", e.to_json())
            } else {
                e.to_text()
            }
        }
    })
}
