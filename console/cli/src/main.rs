//! `golconda`: read and explain a Golconda system's configuration, and push its admin vars.

use golconda_core::check;
use golconda_core::diff::{Change, diff};
use golconda_core::document::{self, parse_value};
use golconda_core::eval::Iets;
use golconda_core::system::System;
use golconda_core::vars::{self, Program, Remote, Store};
use std::io::Read;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage:
  golconda --version | --help
  golconda config show [--set] [--json] [-f FILE] [--system SYSTEM]
  golconda config explain [--json] [-f FILE] [--system SYSTEM] MODULE OPTION
  golconda vars set [--vars DIR] HOST VAR FILE      (the value on stdin)
  golconda vars push [--vars DIR] -i IDENTITY HOST [VAR...]
  golconda vars list [--vars DIR] HOST
  golconda vars pub HOST VAR FILE
  golconda config set [-f FILE] [--system SYSTEM] MODULE [OPTION] VALUE
  golconda config delete [-f FILE] [--system SYSTEM] MODULE [OPTION]
  golconda config validate [-f FILE] [--system SYSTEM]
  golconda diff [--json] [-f FILE] [--system SYSTEM] [REV | --from OTHER]

  -f FILE          the system's document (default: server.toml)
  --system SYSTEM  the Nix system to evaluate for (default: this machine's)
  --set            only what the document sets
  --json           JSON instead of text
  --from OTHER     diff: against the document OTHER (default: git's REV, default HEAD)
  --vars DIR       the age-encrypted admin vars, DIR/HOST/VAR/FILE.age, encrypted to the
                   keys in DIR/recipients.txt (default: vars)
  -i IDENTITY      the age identity that decrypts them (or GOLCONDA_AGE_IDENTITY)

OPTION is dotted below the module (networks.lan.network.DNS). VALUE is TOML (22, \"22\",
[\"a\"], { a = 1 }); text that is not TOML is a string. set and delete write the document only
when the result passes the schema and evaluates; comments and layout stay as written.
diff lists the set and delete operations from the other side's effective configuration to
FILE's, defaults included.

iets comes from PATH, or GOLCONDA_IETS. ssh and age come from PATH, or GOLCONDA_SSH and
GOLCONDA_AGE (a program and its arguments, such as \"ssh -p 2222\" or rage).";

struct Args {
    group: String,
    command: String,
    file: PathBuf,
    system: String,
    set_only: bool,
    json: bool,
    vars: PathBuf,
    identity: Option<PathBuf>,
    from: Option<PathBuf>,
    rest: Vec<String>,
}

fn parse(argv: &[String]) -> Result<Args, String> {
    let mut it = argv.iter();
    let group = it.next().cloned().ok_or("give a command")?;
    // diff has no subcommand: the word after it is an operand
    let command = if group == "diff" {
        "diff".to_string()
    } else {
        it.next().cloned().unwrap_or_default()
    };
    let known = match group.as_str() {
        "config" => ["show", "explain", "set", "delete", "validate"].contains(&command.as_str()),
        "vars" => ["set", "push", "list", "pub"].contains(&command.as_str()),
        "diff" => true,
        _ => return Err(format!("unknown command {group}")),
    };
    if !known {
        return Err(format!("unknown command {group} {command}"));
    }
    let mut a = Args {
        group,
        command,
        file: "server.toml".into(),
        system: format!("{}-linux", std::env::consts::ARCH),
        set_only: false,
        json: false,
        vars: "vars".into(),
        identity: std::env::var_os("GOLCONDA_AGE_IDENTITY")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from),
        from: None,
        rest: Vec::new(),
    };
    // the document flags: config and diff
    let config = a.group == "config" || a.group == "diff";
    while let Some(arg) = it.next() {
        let mut value = || it.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "-f" | "--file" if config => a.file = value()?.into(),
            "--system" if config => a.system = value()?,
            "--set" if a.command == "show" => a.set_only = true,
            "--json" if ["show", "explain", "diff"].contains(&a.command.as_str()) => a.json = true,
            "--from" if a.command == "diff" => a.from = Some(value()?.into()),
            "--vars" if !config && a.command != "pub" => a.vars = value()?.into(),
            "-i" | "--identity" if a.command == "push" => a.identity = Some(value()?.into()),
            f if f.starts_with("--") || (f.starts_with('-') && f.len() > 1) => {
                return Err(format!("unknown flag {f}"));
            }
            _ => a.rest.push(arg.clone()),
        }
    }
    let (min, max) = match (a.group.as_str(), a.command.as_str()) {
        ("config", "explain") => (2, 2),
        ("config", "set") => (2, 3),
        ("config", "delete") => (1, 2),
        ("config", _) => (0, 0),
        ("diff", _) if a.from.is_none() => (0, 1),
        ("diff", _) => (0, 0),
        ("vars", "set" | "pub") => (3, 3),
        ("vars", "list") => (1, 1),
        _ => (1, usize::MAX), // vars push HOST [VAR...]
    };
    if a.rest.len() < min || a.rest.len() > max {
        return Err(format!("{} {} takes other operands", a.group, a.command));
    }
    if a.command == "push" && a.identity.is_none() {
        return Err("vars push needs -i IDENTITY (or GOLCONDA_AGE_IDENTITY)".into());
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
    if a.group == "vars" {
        return run_vars(a);
    }
    let iets = Iets::from_env();
    let file = a.file.display();
    // MODULE [OPTION] [VALUE]: the option path, empty for the module itself
    let path = |option: Option<&String>| -> Vec<String> {
        option
            .map(|o| o.split('.').map(str::to_string).collect())
            .unwrap_or_default()
    };
    match a.command.as_str() {
        "validate" => {
            check::validate(&iets, &a.file, &a.system)?;
            return Ok(format!("{file}: valid\n"));
        }
        "set" => {
            let (value, option) = a.rest[1..].split_last().unwrap();
            let p = path(option.first());
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            check::apply(&iets, &a.file, &a.system, |text| {
                document::set(text, &a.rest[0], &p, parse_value(value))
            })?;
            return Ok(String::new());
        }
        "delete" => {
            let p = path(a.rest.get(1));
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            check::apply(&iets, &a.file, &a.system, |text| {
                document::delete(text, &a.rest[0], &p)
            })?;
            return Ok(String::new());
        }
        "diff" => {
            let after = System::load(&iets, &a.file, &a.system)?;
            let before = match &a.from {
                Some(other) => System::load(&iets, other, &a.system)?,
                None => {
                    let rev = a.rest.first().map_or("HEAD", String::as_str);
                    let text = System::git_text(&a.file, rev)?;
                    System::load_text(&iets, &a.file, &text, &a.system)?
                }
            };
            let changes = diff(&before.config, &after.config);
            return Ok(if a.json {
                let v: Vec<_> = changes.iter().map(Change::to_json).collect();
                format!("{:#}\n", serde_json::Value::Array(v))
            } else {
                changes.iter().map(|c| c.to_text() + "\n").collect()
            });
        }
        _ => {}
    }
    let sys = System::load(&iets, &a.file, &a.system)?;
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

fn run_vars(a: &Args) -> Result<String, Box<dyn std::error::Error>> {
    let store = Store::new(&a.vars, Program::from_env("GOLCONDA_AGE", "age"));
    let remote = || Remote::new(Program::from_env("GOLCONDA_SSH", "ssh"), &a.rest[0]);
    Ok(match a.command.as_str() {
        "set" => {
            let mut value = Vec::new();
            std::io::stdin().read_to_end(&mut value)?;
            let path = store.set(&a.rest[0], &a.rest[1], &a.rest[2], &value)?;
            format!("stored {}\n", path.display())
        }
        "push" => {
            let identity = a.identity.as_deref().expect("parse checks it");
            let p = vars::push(&store, identity, &remote()?, &a.rest[0], &a.rest[1..])?;
            let mut out = String::new();
            for id in &p.sealed {
                out.push_str(&format!("sealed {id}\n"));
            }
            for unit in &p.restarted {
                out.push_str(&format!("restarted {unit}\n"));
            }
            out
        }
        "list" => vars::list(&store, &remote()?, &a.rest[0])?,
        _ => String::from_utf8(remote()?.public(&a.rest[1], &a.rest[2])?)?,
    })
}
