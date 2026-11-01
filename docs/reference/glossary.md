# Glossary

- **A/B**: two copies of `/usr` and two UKIs; an update goes to the inactive one.
- **adios**: the module system. A tree of modules with typed options (korora), composed by explicit
  function application; `modules/` is Golconda's tree.
- **app**: a typed value (`modules/lib/app.nix`) describing what a program needs to run: package,
  program, argv, env, files. It has nothing systemd-specific; a `service` embeds one.
- **bootstrap credential**: a systemd credential delivered by SMBIOS, qemu fw_cfg or the ESP at
  first boot (the host name). Not a var: it carries no secret.
- **build host**: the machine whose Nix daemon builds packages and images, with `ca-derivations`,
  `dynamic-derivations` and `builder-rpc-v0` ([Build host](build-host.md)).
- **composer**: the `/system` module. It unions fragments into one system and refuses duplicates.
- **credential**: a file a service receives from systemd at start (`LoadCredentialEncrypted=`),
  readable as `%d/<name>` in `argv`. The on-disk form is sealed to the TPM in
  `/etc/credstore.encrypted/<var>.<file>`.
- **DPS**: Discoverable Partitions Specification, the type GUIDs systemd-gpt-auto-generator reads.
- **factory**: `/usr/share/factory/etc`, the seed for `/etc`, written by the `/factory` module and
  linked into `/etc` by tmpfiles `L` lines.
- **farm** (symlink farm): `/usr/bin`, `/usr/lib` and `/usr/share` as symlinks into
  `/usr/nix/store`, made by the `/usr` tree builder from the composer's `links` map. The word means
  only the tree; the link kind `farm` names a directory expanded file by file into it.
- **fragment**: the typed value a module returns:
  `{ name; units; files; sysusers; tmpfiles; packages; links }`, every field optional
  (`modules/lib/fragment.nix`).
- **iets**: the evaluator. Evaluates the Nix expressions, lints them strictly (`iets.toml`), and
  talks to the Nix daemon that builds.
- **korora**: the type library adios uses; every option and every shared type (`modules/lib/`) is a
  korora type, and `lib/schema.nix` exports them as JSON Schema.
- **launcher**: a repkgs `launch` record, a small program that runs another with fixed arguments and
  environment. Used for developer tools shipped to other hosts, not for services.
- **link**: one symlink of `/usr` in a fragment's `links` map: `{ target; kind; }` under its path;
  the kind (`package`, `farm`, `dlopen`, `explicit`) tells the builder what to do with it.
- **PCR**: a TPM Platform Configuration Register; PCR 11 holds the UKI measurements.
- **prefixed package**: a package compiled with `prefix = "/usr"` (systemd, dbus-broker, openssh)
  because it addresses its own files by absolute path; reached through the farm.
- **relocatable**: an output that refers to other store paths only relative to itself.
- **repkgs**: the package set and build system Golconda pins (a fork, branch `reloc-boot`). Every
  output is relocatable; builders are nushell; packages declare `bin` and `features`.
- **service**: a typed value (`modules/lib/service.nix`) that embeds an `app` and adds credentials,
  state, user, sandbox tier and ordering. `render service` returns a fragment.
- **slot**: one of the two `/usr` partition triples (usr, verity, signature) of the A/B layout; each
  has its own UKI. An update writes to the inactive slot.
- **UKI**: Unified Kernel Image, one signed PE file with the stub, the kernel, the initrd, the
  cmdline and the PCR signature; one per slot on the ESP.
- **var**: a value the image names but never contains. Class `local`: a oneshot unit generates it on
  the machine on first boot and seals it; class `admin`: the deploy host pushes it and the machine
  seals it. Declared with the helpers in `modules/lib/var.nix`
  ([/vars](../reference/modules/README.md)).
- **verity**: dm-verity, block-level integrity of a read-only partition against a root hash.
