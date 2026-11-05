# Glossary

- **A/B**: two copies of `/usr` and two UKIs; an update goes to the inactive one.
- **adios**: the module system. A tree of modules with typed options (korora), composed by explicit
  function application; `modules/` is Golconda's tree.
- **app**: a typed value (`modules/lib/app.nix`) describing what a program needs to run: package,
  program, argv, env, files. It has nothing systemd-specific; a `service` embeds one.
- **bless-boot**: `systemd-bless-boot`, which marks a counted boot entry good once
  `boot-complete.target` is reached ([Boot: Boot counting](../design/boot.md#boot-counting-and-ab)).
- **boot counting**: the `+3-0` suffix on a UKI's file name; systemd-boot lowers it on each attempt
  and prefers another entry when it reaches `+0-3`.
- **bootstrap credential**: a systemd credential delivered by SMBIOS, qemu fw_cfg or the ESP at
  first boot (the host name). Not a var: it carries no secret.
- **build host**: the machine whose Nix daemon builds packages and images, with `ca-derivations`,
  `dynamic-derivations` and `builder-rpc-v0` ([Build host](build-host.md)).
- **composer**: the `/system` module. It unions fragments into one system and refuses duplicates.
- **confext**: a systemd configuration extension, a tree that `systemd-confext` merges onto `/etc`.
  Golconda's `/etc` is one directory confext, `/usr/lib/confexts/golconda`, built by `lib/etc.nix`
  and merged read-only ([Layout: The read-only /etc](../design/layout.md#the-read-only-etc)).
- **credential**: a file a service receives from systemd at start (`LoadCredentialEncrypted=`),
  readable as `%d/<name>` in `argv`. The on-disk form is sealed to the TPM in
  `/var/lib/golconda/credstore.encrypted/<var>.<file>`.
- **downstream package**: a package in `packages/` beside the document. One that takes the name of a
  Golconda or repkgs package replaces it only when `[golconda] replaces` lists that name
  ([Configuration](config.md#your-own-packages)).
- **DPS**: Discoverable Partitions Specification, the type GUIDs systemd-gpt-auto-generator reads.
- **ESP**: EFI System Partition, the FAT partition the firmware reads; it holds systemd-boot, the
  UKIs and `loader/credentials/`.
- **factory**: `/usr/share/factory/etc`, the files `/etc` links to, written by the `/factory` module
  and linked into the confext by tmpfiles `L` lines at build time.
- **farm** (symlink farm): `/usr/bin`, `/usr/lib` and `/usr/share` as symlinks into
  `/usr/nix/store`, made by the `/usr` tree builder from the composer's `links` map. The word means
  only the tree; the link kind `farm` names a directory expanded file by file into it.
- **fragment**: the typed value a module returns:
  `{ name; units; files; sysusers; tmpfiles; packages; links }`, every field optional
  (`modules/lib/fragment.nix`).
- **health unit**: a unit that must pass before `boot-complete.target`:
  `golconda-health-network.service` (a routable link) and `golconda-health-sshd.service` (sshd
  active) ([Boot: Boot health](../design/boot.md#boot-health)).
- **iets**: the evaluator. Evaluates the Nix expressions, lints them strictly (`iets.toml`), and
  talks to the Nix daemon that builds.
- **IPE**: Integrity Policy Enforcement, the kernel LSM that lets a program run only from a
  dm-verity volume whose signature the kernel verified ([Kernel](../design/kernel.md)).
- **korora**: the type library adios uses; every option and every shared type (`modules/lib/`) is a
  korora type, and `lib/schema.nix` exports them as JSON Schema.
- **launcher**: a repkgs `launch` record, a small program that runs another with fixed arguments and
  environment. Used for developer tools shipped to other hosts, not for services.
- **link**: one symlink of `/usr` in a fragment's `links` map: `{ target; kind; }` under its path;
  the kind (`package`, `farm`, `dlopen`, `explicit`) tells the builder what to do with it.
- **`/local`**: the module path of the `modules/` directory beside the document; its modules are
  selected by their table like any optional module ([Configuration](config.md#your-own-modules)).
- **PCR**: a TPM Platform Configuration Register; PCR 11 holds the UKI measurements.
- **prefixed package**: a package compiled with `prefix = "/usr"` (systemd, dbus-broker, openssh)
  because it addresses its own files by absolute path; reached through the farm.
- **release key**: the OpenPGP key (`release/index.key`) that signs a release's `SHA256SUMS`; its
  public half is the image's keyring for `Verify=yes`
  ([Releases: The signed index](../design/releases.md#the-signed-index)).
- **relocatable**: an output that refers to other store paths only relative to itself.
- **repkgs**: the package set and build system Golconda pins (a fork, branch `upstream-prep`). Every
  output is relocatable; builders are nushell; packages declare `bin` and `features`.
- **SBOM**: Software Bill of Materials, `/usr/lib/golconda/sbom.json` in CycloneDX, with a purl and
  a cpe per component ([Image artifacts](image.md#software-bill-of-materials)).
- **service**: a typed value (`modules/lib/service.nix`) that embeds an `app` and adds credentials,
  state, user, sandbox tier and ordering. `render service` returns a fragment.
- **slot**: one of the two `/usr` partition triples (usr, verity, signature) of the A/B layout; each
  has its own UKI. An update writes to the inactive slot.
- **sysupdate**: `systemd-sysupdate`, which fetches a release and writes it to the inactive slot
  ([Updates](../design/updates.md)).
- **UKI**: Unified Kernel Image, one signed PE file with the stub, the kernel, the initrd, the
  cmdline and the PCR signature; one per slot on the ESP.
- **var**: a value the image names but never contains. Class `local`: a oneshot unit generates it on
  the machine on first boot and seals it; class `admin`: the deploy host pushes it and the machine
  seals it. Declared with the helpers in `modules/lib/var.nix`
  ([/vars](../reference/modules/README.md)).
- **verity**: dm-verity, block-level integrity of a read-only partition against a root hash.
