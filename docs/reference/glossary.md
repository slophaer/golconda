# Glossary

- **A/B**: two copies of `/usr` and two UKIs; updates go to the inactive one.
- **app**: a typed value in `modules/lib/app.nix` describing what a program needs to run: package,
  argv, env, files. It has nothing systemd-specific; `service` embeds one.
- **composer**: the `/system` module that unions fragments into one system.
- **DDI**: Discoverable Disk Image, a GPT image following the DPS that systemd tools can mount.
- **delivery class**: how a secret reaches the machine. Three classes: machine-local (generated on
  first boot), admin-supplied (pushed over ssh, sealed on the machine), bootstrap (ESP/SMBIOS
  credentials).
- **DPS**: Discoverable Partitions Specification, the type GUIDs systemd-gpt-auto-generator reads.
- **etc.manifest**: `/usr/lib/golconda/etc.manifest`, written by the composer. Lists type, mode,
  owner and sha256 for each factory file. Used by `etc-sync` *(planned)* to detect admin changes.
- **farm package**: a package compiled with an absolute `/usr` prefix (systemd, dbus-broker,
  openssh). Reached through the symlink farm; the `prefix` field in repkgs marks them.
- **fragment**: the typed value a module returns: `{ units; files; sysusers; tmpfiles; packages }`.
  See [Modules](../design/modules.md).
- **PCR**: a TPM Platform Configuration Register; PCR 11 holds the UKI measurements.
- **relocatable**: an output that refers to other store paths only relative to itself.
- **service**: a typed value in `modules/lib/service.nix` that embeds an `app` and adds credentials,
  state, user, sandbox, and ordering. `render service` returns a fragment with a systemd unit.
- **slot**: one of the two `/usr` partitions in the A/B layout. Updates write to the inactive slot.
- **symlink farm**: `/usr/bin` and friends as links into `/usr/nix/store`.
- **UKI**: Unified Kernel Image, one signed PE file with stub, kernel, initrd and cmdline.
- **var**: a value generated on the machine at first boot and sealed to the TPM. Declared in the
  image; produced by a oneshot unit. See [vars](modules/vars.md).
- **verity**: dm-verity, block-level integrity of a read-only partition against a root hash.
