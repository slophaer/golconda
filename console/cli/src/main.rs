//! `golconda`: read, explain and change a Golconda system's configuration, and push its
//! admin vars.

use clap::{Args, CommandFactory, Parser, Subcommand};
use golconda_core::check;
use golconda_core::diff::{Change, against_git, diff};
use golconda_core::document::{self, parse_path, parse_value};
use golconda_core::eval::Iets;
use golconda_core::system::System;
use golconda_core::vars::{self, Program, Remote, Store};
use std::io::Read;
use std::path::PathBuf;
use std::process::ExitCode;

/// Read, explain and change a Golconda system's configuration.
///
/// OPTION is a TOML dotted key below the module (networks.lan.network.DNS, networks."lan.1").
/// VALUE is TOML (22, "22", ["a"], { a = 1 }); text that is not TOML is a string; a value
/// that starts with a dash and is not a number goes after `--`. set and delete write the
/// document only when the result passes the schema and evaluates; comments and layout stay
/// as written. iets comes from PATH, or GOLCONDA_IETS; ssh and age from PATH, or GOLCONDA_SSH
/// and GOLCONDA_AGE (a program and its arguments, such as "ssh -p 2222" or rage).
#[derive(Parser)]
#[command(version, verbatim_doc_comment)]
struct Cli {
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
        module: String,
        /// The option (a TOML dotted key), then the value (TOML, or else a string)
        #[arg(num_args = 1..=2, required = true, value_name = "[OPTION] VALUE")]
        operands: Vec<String>,
    },
    /// Delete an option (or, without OPTION, the module)
    Delete {
        #[command(flatten)]
        doc: Doc,
        module: String,
        option: Option<String>,
    },
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
    #[arg(long, default_value_t = format!("{}-linux", std::env::consts::ARCH))]
    system: String,
}

fn main() -> ExitCode {
    // usage errors exit 2 (clap's)
    match run(Cli::parse().command) {
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

fn run(command: Command) -> Result<String, Box<dyn std::error::Error>> {
    let iets = Iets::from_env();
    let config = match command {
        Command::Diff {
            doc,
            json,
            from,
            rev,
        } => {
            let changes = match from {
                Some(other) => {
                    let before = System::load(&iets, &other, &doc.system)?;
                    let after = System::load(&iets, &doc.file, &doc.system)?;
                    diff(&before.config, &after.config)
                }
                None => against_git(&iets, &doc.file, &rev, &doc.system)?.1,
            };
            return Ok(if json {
                let v: Vec<_> = changes.iter().map(Change::to_json).collect();
                format!("{:#}\n", serde_json::Value::Array(v))
            } else {
                changes.iter().map(|c| c.to_text() + "\n").collect()
            });
        }
        Command::Config(c) => c,
        Command::Vars(v) => return run_vars(v),
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
        } => {
            let p = path(option.as_ref())?;
            let p: Vec<&str> = p.iter().map(String::as_str).collect();
            check::apply(&iets, &doc.file, &doc.system, |text| {
                document::delete(text, &module, &p)
            })?;
            String::new()
        }
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

fn run_vars(command: Vars) -> Result<String, Box<dyn std::error::Error>> {
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
            std::io::stdin().read_to_end(&mut value)?;
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
                    std::env::var_os("GOLCONDA_AGE_IDENTITY")
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
