//! Machines: which hosts run which system, and how the console reads and drives them.
//!
//! `machines.toml` in the configuration repository names them, so a change to the fleet is a
//! commit like any other:
//!
//! ```toml
//! [server]
//! updates = "hetzner:updates/web"    # where release publish puts this system's releases
//! [server.machines.web1]
//! ssh = "root@web1.example.com"
//! ```
//!
//! A machine is read through systemd's varlink interfaces, with `varlinkctl` run on it over
//! ssh: the hostname and image version (io.systemd.Hostname), the boot entries and their
//! counters (io.systemd.BootControl) and whether a newer version is there
//! (io.systemd.SysUpdate). The image gets nothing new for it.

use crate::vars::{Program, word};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::result;
use std::thread;
use std::time::{Duration, Instant};
use toml_edit::DocumentMut;

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct Error(pub String);

pub type Result<T> = result::Result<T, Error>;

fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Machine {
    pub name: String,
    /// what ssh connects to: `user@host`, `host`, or `ssh://user@host:port`
    pub ssh: String,
}

/// One system's machines.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Fleet {
    /// the rclone destination its releases are published to, which the machines'
    /// `/system.updateSource` serves
    pub updates: Option<String>,
    pub machines: BTreeMap<String, Machine>,
}

/// An ssh destination ssh takes as one: no space, and no leading dash, which ssh would read as
/// an option (`-oProxyCommand=…`).
fn destination(s: &str) -> Result<&str> {
    if s.is_empty() || s.starts_with('-') || s.contains(char::is_whitespace) {
        return err(format!("'{s}' is not an ssh destination"));
    }
    Ok(s)
}

/// Reads `machines.toml`: system name -> its fleet.
pub fn parse(text: &str) -> Result<BTreeMap<String, Fleet>> {
    let doc: DocumentMut = text
        .parse()
        .map_err(|e| Error(format!("machines.toml: {e}")))?;
    let mut out = BTreeMap::new();
    for (system, t) in doc.iter() {
        let t = t
            .as_table_like()
            .ok_or_else(|| Error(format!("machines.toml: [{system}] is not a table")))?;
        word(system).map_err(|e| Error(format!("machines.toml: {e}")))?;
        let mut fleet = Fleet::default();
        for (k, v) in t.iter() {
            match k {
                "updates" => {
                    let u = v.as_str().ok_or_else(|| {
                        Error(format!("machines.toml: {system}.updates is not a string"))
                    })?;
                    fleet.updates = Some(u.to_string());
                }
                "machines" => {
                    let ms = v.as_table_like().ok_or_else(|| {
                        Error(format!("machines.toml: {system}.machines is not a table"))
                    })?;
                    for (name, m) in ms.iter() {
                        word(name).map_err(|e| Error(format!("machines.toml: {e}")))?;
                        let ssh = m.get("ssh").and_then(|s| s.as_str()).ok_or_else(|| {
                            Error(format!(
                                "machines.toml: {system}.machines.{name} has no ssh"
                            ))
                        })?;
                        let ssh = destination(ssh).map_err(|e| {
                            Error(format!("machines.toml: {system}.machines.{name}: {e}"))
                        })?;
                        fleet.machines.insert(
                            name.to_string(),
                            Machine {
                                name: name.to_string(),
                                ssh: ssh.to_string(),
                            },
                        );
                    }
                }
                other => {
                    return err(format!(
                        "machines.toml: {system}.{other}: only updates and machines"
                    ));
                }
            }
        }
        out.insert(system.to_string(), fleet);
    }
    Ok(out)
}

/// A boot entry as io.systemd.BootControl lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: String,
    pub version: Option<String>,
    pub default: bool,
    pub selected: bool,
    /// boot counting: None once the entry is blessed (or never counted)
    pub tries_left: Option<i64>,
    pub tries_done: Option<i64>,
}

impl Entry {
    /// A Golconda image's entry (type 2, a UKI), not one the loader adds by itself.
    pub fn is_image(&self) -> bool {
        self.version.is_some()
    }

    pub fn blessed(&self) -> bool {
        self.tries_left.is_none()
    }
}

/// What a machine says about itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub hostname: String,
    pub image: Option<String>,
    pub version: Option<String>,
    pub boot_id: String,
    pub entries: Vec<Entry>,
    /// Ok(Some(v)): a newer version at the update source; Ok(None): none; Err: it could not
    /// look (the source unreachable, say)
    pub available: result::Result<Option<String>, String>,
}

impl Status {
    pub fn to_json(&self) -> Value {
        let entries: Vec<Value> = self
            .entries
            .iter()
            .map(|e| {
                json!({ "id": e.id, "version": e.version, "default": e.default,
                        "selected": e.selected, "triesLeft": e.tries_left, "triesDone": e.tries_done })
            })
            .collect();
        let (available, check) = match &self.available {
            Ok(v) => (json!(v), Value::Null),
            Err(e) => (Value::Null, json!(e)),
        };
        json!({ "hostname": self.hostname, "image": self.image, "version": self.version,
                "bootId": self.boot_id, "entries": entries, "available": available,
                "checkError": check })
    }

    /// The image entry the machine booted.
    pub fn booted(&self) -> Option<&Entry> {
        self.entries.iter().find(|e| e.selected && e.is_image())
    }
}

/// How the console reaches machines: ssh, which runs systemd's own programs there (the image
/// has no other tools).
pub struct Remote<'a> {
    pub ssh: &'a Program,
}

const SYSUPDATE: &str = "/usr/lib/systemd/systemd-sysupdate";

impl Remote<'_> {
    fn args<'b>(machine: &'b Machine, command: &'b str) -> [&'b str; 7] {
        // BatchMode: a job never waits for a password; `--`: the destination is no option
        [
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "--",
            machine.ssh.as_str(),
            command,
        ]
    }

    fn run(&self, machine: &Machine, command: &str) -> Result<String> {
        self.ssh
            .run(&Self::args(machine, command), None)
            .map(|o| String::from_utf8_lossy(&o).into_owned())
            .map_err(|e| Error(format!("{}: {}", machine.name, e.0)))
    }

    /// A varlink method on the machine, through varlinkctl there: its answers, one per line.
    fn call(
        &self,
        machine: &Machine,
        socket: &str,
        method: &str,
        params: &Value,
        more: bool,
    ) -> Result<Vec<Value>> {
        let params = params.to_string();
        // the parameters go into single quotes on the machine's shell
        if params.contains('\'') {
            return err(format!("{}: a quote in varlink parameters", machine.name));
        }
        let more = if more { " --more" } else { "" };
        let out = self.run(
            machine,
            &format!(
                "varlinkctl call --json=short{more} /run/systemd/{socket} {method} '{params}'"
            ),
        )?;
        out.lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| {
                serde_json::from_str(l)
                    .map_err(|e| Error(format!("{}: {method}: {e}", machine.name)))
            })
            .collect()
    }

    /// The machine's hostname, image, version, boot id, boot entries, and whether its update
    /// source has a newer version.
    pub fn status(&self, machine: &Machine) -> Result<Status> {
        let d = self
            .call(
                machine,
                "io.systemd.Hostname",
                "io.systemd.Hostname.Describe",
                &json!({}),
                false,
            )?
            .into_iter()
            .next()
            .unwrap_or(Value::Null);
        let entries = self
            .call(
                machine,
                "io.systemd.BootControl",
                "io.systemd.BootControl.ListBootEntries",
                &json!({}),
                true,
            )?
            .into_iter()
            .map(|e| {
                let e = &e["entry"];
                Entry {
                    id: e["id"].as_str().unwrap_or("").into(),
                    version: e["version"].as_str().map(str::to_string),
                    default: e["isDefault"] == true,
                    selected: e["isSelected"] == true,
                    tries_left: e["triesLeft"].as_i64(),
                    tries_done: e["triesDone"].as_i64(),
                }
            })
            .collect();
        let available = match self.call(
            machine,
            "io.systemd.SysUpdate",
            "io.systemd.SysUpdate.CheckNew",
            &json!({ "target": { "class": "host" } }),
            false,
        ) {
            Ok(v) => Ok(v
                .first()
                .and_then(|a| a["available"].as_str())
                .map(str::to_string)),
            Err(e) if e.0.contains("NoUpdateNeeded") => Ok(None),
            Err(e) => Err(e.0),
        };
        let s = |k: &str| d[k].as_str().map(str::to_string);
        Ok(Status {
            hostname: s("Hostname").unwrap_or_default(),
            image: s("OperatingSystemImageID"),
            version: s("OperatingSystemImageVersion"),
            boot_id: s("BootID").unwrap_or_default(),
            entries,
            available,
        })
    }

    /// Runs `command` there, each line of its output (standard error with it) to `log`.
    fn stream(&self, machine: &Machine, command: &str, log: &mut dyn FnMut(&str)) -> Result<()> {
        let with_err = format!("{command} 2>&1");
        let (ok, stderr) = self
            .ssh
            .stream(&Self::args(machine, &with_err), log)
            .map_err(|e| Error(e.0))?;
        if ok {
            Ok(())
        } else {
            err(format!(
                "{}: {command} failed: {}",
                machine.name,
                stderr.trim()
            ))
        }
    }

    /// sysupdate fetches the newest version from the update source and writes it to the free
    /// slot; the machine boots it at the next reboot.
    pub fn update(&self, machine: &Machine, log: &mut dyn FnMut(&str)) -> Result<()> {
        self.stream(machine, &format!("{SYSUPDATE} update"), log)
    }

    /// Asks the machine to reboot (io.systemd.Shutdown, logind's: an inhibitor a service holds
    /// stops it, and says who and why). It answers before it goes down.
    pub fn reboot(&self, machine: &Machine, log: &mut dyn FnMut(&str)) -> Result<()> {
        self.call(
            machine,
            "io.systemd.Shutdown",
            "io.systemd.Shutdown.Reboot",
            &json!({}),
            false,
        )?;
        log(&format!("{}: rebooting", machine.name));
        Ok(())
    }

    /// The next boot, once, goes to the other image entry: the slot it does not run.
    pub fn rollback(&self, machine: &Machine, log: &mut dyn FnMut(&str)) -> Result<String> {
        let st = self.status(machine)?;
        let running = st.booted().map(|e| e.id.clone());
        let Some(other) = st
            .entries
            .iter()
            .find(|e| e.is_image() && Some(&e.id) != running.as_ref())
        else {
            return err(format!("{}: no other image to go back to", machine.name));
        };
        let version = other.version.clone().unwrap_or_default();
        // the id comes from the machine and goes to its shell: only what an entry file name holds
        let plain = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+' | '@');
        if other.id.is_empty() || !other.id.chars().all(plain) {
            return err(format!(
                "{}: the boot entry {:?} is no plain name",
                machine.name, other.id
            ));
        }
        self.stream(machine, &format!("bootctl set-oneshot {}", other.id), log)?;
        self.reboot(machine, log)?;
        Ok(version)
    }
}

/// When to look again while a machine comes back, and for how long.
pub struct Patience {
    pub every: Duration,
    pub until: Duration,
}

/// Waits for `machine` to be back after a reboot: another boot id, running `version`, and its
/// entry blessed (boot-complete.target was reached and the counter removed). Unreachable while
/// it reboots is expected.
pub fn confirm(
    remote: &Remote<'_>,
    machine: &Machine,
    old_boot: &str,
    version: &str,
    patience: &Patience,
    log: &mut dyn FnMut(&str),
) -> Result<()> {
    let start = Instant::now();
    let mut said = String::new();
    loop {
        let now = match remote.status(machine) {
            Err(_) => "not reachable yet".to_string(),
            Ok(st) if st.boot_id == old_boot => "not rebooted yet".to_string(),
            Ok(st) if st.version.as_deref() != Some(version) => {
                return err(format!(
                    "{} came back on {}, not {version}: the boot loader went back to the other slot",
                    machine.name,
                    st.version.unwrap_or_default()
                ));
            }
            Ok(st) if st.booted().is_some_and(Entry::blessed) => {
                log(&format!("{} runs {version}, blessed", machine.name));
                return Ok(());
            }
            Ok(_) => format!("runs {version}, not blessed yet"),
        };
        if now != said {
            log(&format!("{}: {now}", machine.name));
            said = now;
        }
        if start.elapsed() >= patience.until {
            return err(format!(
                "{}: {said} after {}s",
                machine.name,
                patience.until.as_secs()
            ));
        }
        thread::sleep(patience.every);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::time::Duration;
    use tempfile::TempDir;

    /// A machine in a directory, reached through this script instead of ssh: its version, boot
    /// id and slots are files, and it answers the commands the console sends as Golconda's
    /// image does (varlinkctl's JSON, sysupdate, systemctl, bootctl). `down` makes it
    /// unreachable; a reboot boots `pending` (or the one-shot entry) with tries left, and the
    /// second look after it finds that entry blessed.
    const MACHINE: &str = include_str!("testdata/machine.sh");

    struct Box_ {
        _tmp: TempDir,
        m: PathBuf,
        ssh: Program,
    }

    /// web1 running 20261105.1 in one of two slots, blessed, boot id boot-0.
    fn machine() -> Box_ {
        let tmp = TempDir::new().unwrap();
        let m = tmp.path().join("m");
        fs::create_dir_all(&m).unwrap();
        for (f, v) in [
            ("version", "20261105.1"),
            ("boot", "boot-0"),
            ("slots", "20261105.1\n"),
        ] {
            fs::write(m.join(f), v).unwrap();
        }
        let script = tmp.path().join("ssh");
        fs::write(&script, MACHINE).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let ssh = Program::from_env("GOLCONDA_TEST_UNSET_SSH", script.to_str().unwrap());
        Box_ { _tmp: tmp, m, ssh }
    }

    fn web1() -> Machine {
        Machine {
            name: "web1".into(),
            ssh: "root@web1".into(),
        }
    }

    fn set(m: &Path, file: &str, v: &str) {
        fs::write(m.join(file), v).unwrap();
    }

    fn quick() -> Patience {
        Patience {
            every: Duration::from_millis(10),
            until: Duration::from_secs(5),
        }
    }

    #[test]
    fn status_reads_hostname_version_slots_and_what_is_available() {
        let b = machine();
        let r = Remote { ssh: &b.ssh };
        let st = r.status(&web1()).unwrap();
        assert_eq!(
            (
                st.hostname.as_str(),
                st.image.as_deref(),
                st.version.as_deref(),
                st.boot_id.as_str()
            ),
            ("web1", Some("server"), Some("20261105.1"), "boot-0")
        );
        assert_eq!(st.entries.len(), 2);
        assert!(
            st.booted()
                .is_some_and(|e| e.id == "server_20261105.1.efi" && e.blessed())
        );
        assert!(!st.entries[1].is_image(), "the loader's own entry");
        assert_eq!(st.available, Ok(None));
        set(&b.m, "available", "20261106.1");
        assert_eq!(
            r.status(&web1()).unwrap().available,
            Ok(Some("20261106.1".into()))
        );
        set(&b.m, "offline", "");
        let e = r.status(&web1()).unwrap().available.unwrap_err();
        assert!(e.contains("Protocol error"), "{e}");
        assert_eq!(
            r.status(&web1()).unwrap().to_json()["checkError"]
                .as_str()
                .map(|e| e.contains("Protocol")),
            Some(true)
        );
        set(&b.m, "down", "");
        assert!(
            r.status(&web1())
                .unwrap_err()
                .0
                .contains("Connection refused")
        );
    }

    #[test]
    fn update_reboot_and_confirm_bring_the_new_version_up_blessed() {
        let b = machine();
        let r = Remote { ssh: &b.ssh };
        set(&b.m, "available", "20261106.1");
        let mut log = Vec::new();
        r.update(&web1(), &mut |l| log.push(l.to_string())).unwrap();
        assert!(
            log.iter()
                .any(|l| l.contains("Successfully installed update '20261106.1'")),
            "{log:?}"
        );
        r.reboot(&web1(), &mut |l| log.push(l.to_string())).unwrap();
        confirm(&r, &web1(), "boot-0", "20261106.1", &quick(), &mut |l| {
            log.push(l.to_string());
        })
        .unwrap();
        assert!(log.iter().any(|l| l.contains("not blessed yet")), "{log:?}");
        assert_eq!(log.last().unwrap(), "web1 runs 20261106.1, blessed");
    }

    #[test]
    fn confirm_fails_when_the_loader_falls_back_or_the_machine_stays_away() {
        let b = machine();
        let r = Remote { ssh: &b.ssh };
        set(&b.m, "available", "20261106.1");
        r.update(&web1(), &mut |_| {}).unwrap();
        set(&b.m, "fallback", "");
        r.reboot(&web1(), &mut |_| {}).unwrap();
        let e = confirm(&r, &web1(), "boot-0", "20261106.1", &quick(), &mut |_| {}).unwrap_err();
        assert!(
            e.0.contains("came back on 20261105.1, not 20261106.1"),
            "{e}"
        );
        set(&b.m, "down", "");
        let short = Patience {
            every: Duration::from_millis(10),
            until: Duration::from_millis(50),
        };
        let mut log = Vec::new();
        let e = confirm(&r, &web1(), "boot-0", "20261106.1", &short, &mut |l| {
            log.push(l.to_string());
        })
        .unwrap_err();
        assert!(e.0.contains("not reachable yet after"), "{e}");
        assert_eq!(log, ["web1: not reachable yet"], "said once");
    }

    #[test]
    fn an_inhibitor_stops_a_reboot() {
        let b = machine();
        set(&b.m, "inhibited", "");
        let e = Remote { ssh: &b.ssh }
            .reboot(&web1(), &mut |_| {})
            .unwrap_err();
        assert!(e.0.contains("BlockedByInhibitor"), "{e}");
        assert_eq!(fs::read_to_string(b.m.join("boot")).unwrap(), "boot-0");
    }

    #[test]
    fn a_machine_that_does_not_reboot_is_not_confirmed() {
        let b = machine();
        let r = Remote { ssh: &b.ssh };
        let short = Patience {
            every: Duration::from_millis(10),
            until: Duration::from_millis(50),
        };
        let e = confirm(&r, &web1(), "boot-0", "20261105.1", &short, &mut |_| {}).unwrap_err();
        assert!(e.0.contains("not rebooted yet"), "{e}");
    }

    #[test]
    fn rollback_boots_the_other_slot_once() {
        let b = machine();
        let r = Remote { ssh: &b.ssh };
        set(&b.m, "slots", "20261104.2\n20261105.1\n");
        let v = r.rollback(&web1(), &mut |_| {}).unwrap();
        assert_eq!(v, "20261104.2");
        let log = fs::read_to_string(b.m.join("log")).unwrap();
        assert!(
            log.contains("bootctl set-oneshot server_20261104.2.efi"),
            "{log}"
        );
        confirm(&r, &web1(), "boot-0", "20261104.2", &quick(), &mut |_| {}).unwrap();
        set(&b.m, "slots", "20261104.2\n");
        assert!(
            r.rollback(&web1(), &mut |_| {})
                .unwrap_err()
                .0
                .contains("no other image")
        );
    }

    #[test]
    fn the_destination_goes_after_a_double_dash() {
        let b = machine();
        Remote { ssh: &b.ssh }.status(&web1()).unwrap();
        // the stand-in reads the command as the 7th argument: -o … -o … -- DEST COMMAND
        let log = fs::read_to_string(b.m.join("log")).unwrap();
        assert!(
            log.starts_with("varlinkctl call --json=short /run/systemd/io.systemd.Hostname"),
            "{log}"
        );
    }

    #[test]
    fn machines_toml_names_each_systems_machines_and_update_source() {
        let f = parse(
            "[server]\nupdates = \"hetzner:updates/web\"\n[server.machines.web1]\nssh = \"root@web1\"\n[server.machines.web2]\nssh = \"ssh://root@10.0.0.6:2222\"\n[edge]\n",
        )
        .unwrap();
        assert_eq!(f["server"].updates.as_deref(), Some("hetzner:updates/web"));
        assert_eq!(f["server"].machines["web2"].ssh, "ssh://root@10.0.0.6:2222");
        assert_eq!(f["edge"], Fleet::default());
    }

    #[test]
    fn a_destination_ssh_would_read_as_an_option_is_refused() {
        for bad in ["-oProxyCommand=sh", "root@web 1", ""] {
            let text = format!("[server.machines.web1]\nssh = \"{bad}\"\n");
            assert!(parse(&text).is_err(), "{bad} was taken");
        }
        assert!(parse("[server.machines.web1]\n").is_err(), "no ssh");
        assert!(parse("[server]\nupdate = \"x\"\n").is_err(), "a typo");
        assert!(
            parse("[\"ser ver\".machines.a]\nssh = \"h\"\n").is_err(),
            "a name"
        );
    }

    #[test]
    fn an_entry_id_that_is_no_plain_name_is_not_sent_to_the_shell() {
        let b = machine();
        let r = Remote { ssh: &b.ssh };
        // a machine whose other entry is named to run a command
        set(&b.m, "slots", "20261104.2;reboot\n20261105.1\n");
        let e = r.rollback(&web1(), &mut |_| {}).unwrap_err();
        assert!(e.0.contains("no plain name"), "{e}");
        let log = fs::read_to_string(b.m.join("log")).unwrap();
        assert!(!log.contains("set-oneshot"), "{log}");
    }
}
