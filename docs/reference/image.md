# Image artifacts

The `/usr` tree builder exists (`lib/usr-tree.nix`) and the image chain exists (`lib/image/`):
erofs, verity, initrd, UKI and disk, one derivation each. The `image/` directory holds the
tool-independent definitions they render.

## A release

Names carry the image id and the version; the version sorts with `strverscmp`
([Updates: Versions](../design/updates.md#versions)).

| artifact         | file name                                                    | sysupdate transfer                         |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------ |
| `/usr` image     | `<id>_<version>.usr.raw`                                     | `Type=partition`, `MatchPartitionType=usr` |
| verity hash tree | `<id>_<version>.usr-verity.raw`                              | `MatchPartitionType=usr-verity`            |
| verity signature | `<id>_<version>.usr-verity-sig.raw`                          | `MatchPartitionType=usr-verity-sig`        |
| UKI              | `<id>_<version>.efi` → installed as `<id>_<version>+3-0.efi` | `Type=regular-file`, path `/EFI/Linux`     |
| manifest         | `SHA256SUMS` *(after v1; `Verify=no` in v1)*                 | —                                          |

Each partition transfer finds its slots by GPT label (`image/sysupdate.nix` `slots`, the target
`MatchPattern=`): an installed slot is `usr_<version>`, `usr-verity_<version>` or
`usr-verity-sig_<version>`, a free slot is `_empty`. The disk builder labels slot A from the same
patterns (`slotLabel`, `lib/image/disk.nix`) and the B slots `_empty` (`image/repart.nix`);
sysupdate writes the formatted pattern as the label of the slot it fills. The partition type tells
the three transfers apart, so the label carries no image id: GPT allows 36 characters, the longest
prefix (`usr-verity-sig_`) leaves 21 for the version, and a longer label fails the build.

All transfers use `InstancesMax=2` and `ProtectVersion=%A`. The installed UKI name carries the boot
counter (`+3-0`: three tries left, none done); `systemd-bless-boot` removes the suffix after
`boot-complete.target`.

## Image definitions (`image/`)

| file             | content                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------- |
| `default.nix`    | image identity, the key layout, boot counting; imports the other files                      |
| `erofs.nix`      | erofs compression, the timestamp-from-version rule                                          |
| `os-release.nix` | os-release template (`ID`, `VERSION_ID`, `IMAGE_ID`, `IMAGE_VERSION`, `ARCHITECTURE`)       |
| `repart.nix`     | systemd-repart partition definitions (ESP, usr-a/b, verity, sig, root)                      |
| `sysupdate.nix`  | systemd-sysupdate transfer definitions (usr, verity, sig, UKI), `Path=` from `updateSource` |
| `uki.nix`        | the UKI cmdline template, the PCR phases, the Secure Boot and PCR signing paths             |

The definitions are data. The composer renders `sysupdate.nix` and the root definition of
`repart.nix`; the image builder renders the rest.

## `/usr` tree (`lib/usr-tree.nix`)

`usrTree { composerOutput; platform; version; buildSystem ? platform.name; sbomDrv ? null; }`
produces a derivation whose output **is** the complete `/usr` directory; `mkSystem` calls it with
the artifacts added ([Configuration](config.md#the-entry-point)):

| path                                     | content                                                                                                                                                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix/store/<hash>-*`                     | the runtime closure of `composerOutput.packages`                                                                                                                                                                          |
| `bin/`, `lib/`, `share/`                 | relative symlinks into `nix/store/` (from `links`; kind `farm` expanded)                                                                                                                                                  |
| `sbin`                                   | symlink to `bin`                                                                                                                                                                                                          |
| `lib/systemd/system/<name>`              | unit files (from `composerOutput.units`)                                                                                                                                                                                  |
| `lib/sysusers.d/golconda.conf`           | sysusers lines                                                                                                                                                                                                            |
| `lib/tmpfiles.d/golconda.conf`           | tmpfiles lines                                                                                                                                                                                                            |
| `lib/os-release`                         | rendered from `image/os-release.nix` with the version and the architecture                                                                                                                                                |
| `lib/golconda/packages.json`             | each package with name, version, store path and the fragments that brought it                                                                                                                                             |
| `lib/golconda/{config,schema,sbom}.json` | from `mkSystem`: the normalized options, the schema, the SBOM                                                                                                                                                             |
| `lib/golconda/config.json` fields        | module path → option → `{ value?; explicit }`: `explicit` is true when the TOML (or `extra`) set it, false when the default applies (`value` is missing for a computed default); a package is its name                    |
| `lib/golconda/schema.json` fields        | per option `x-golconda-declaredIn` = `{ module; file; line? }` (file relative to the repo; `line` only when the evaluator reports it: iets does, nix does not); per module `x-golconda-inputs`, the module paths it reads |
| `lib/golconda/attribution.json`          | `{ files; links; units; sysusers; tmpfiles }`, each key (path under `/usr`, unit name, line) → the origins that emitted it: `/base`, a module path, a fragment's `name` or `fragments[<i>]`                               |
| other `lib/`, `share/`                   | files from `composerOutput.files` (paths under `/usr/`, with their mode)                                                                                                                                                  |

Build-time verification: no absolute symlink target; every `dlopen` link resolves and every `farm`
link names a directory; no setuid or setgid bit; no top-level directory other than `bin`, `lib`,
`share`, `nix`, `libexec` and the `sbin` link.

A Nix store path carries no mtimes (Nix sets them to 1), so the tree itself has none. The erofs step
applies the timestamp derived from the version (`YYYYMMDD.N` → epoch seconds, `versionToEpoch`) with
`mkfs.erofs -T`.

## Built today (`lib/image/`)

Each step is a content-addressed derivation with a nushell builder (`common.nix`), repkgs packages
only; `packages.<system>.image-smoke` runs the chain over the system of `examples/server.toml` and
writes `proof.txt` (sizes, `veritysetup verify`, the cpio listing, `ukify inspect`, repart's table).
`image-smoke-<step>` exposes each step.

| step   | function (`lib/image/default.nix`)        | output                                                                                                                                          |
| ------ | ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| erofs  | `erofs { usrTree; … }`                    | `<id>_<version>.usr.raw`: `mkfs.erofs -zlz4hc -T <epoch> -U <uuid> --all-root`; epoch and UUID from the version, so a rebuild is byte-identical |
| verity | `verity { erofs; key; cert; … }`          | `<id>_<version>.usr-verity.raw`, `roothash`, `<id>_<version>.usr-verity-sig.raw`                                                                |
| initrd | `initrdTree { … }`, `initrd { usrTree; }` | `initrd.cpio.zst`, `rdinit` ([Boot: the initrd](../design/boot.md#the-initrd))                                                                  |
| uki    | `uki { initrd; verity; usrTree; keys… }`  | `<id>_<version>+3-0.efi` (`ukiName`), `cmdline`                                                                                                 |
| disk   | `disk { erofs; verity; uki; keys… }`      | `disk.raw` (sparse, fully allotted: ESP with the signed loader and `loader.conf`, A and B slots, no room for `root`), `disk.json`               |

The verity step: `veritysetup format` with a salt and superblock UUID from the version; the
signature is `openssl smime -sign -nocerts -noattr -binary` over the hex root hash, as
systemd-veritysetup documents; the `-sig.raw` file is systemd's partition content, the JSON
`{ rootHash, certificateFingerprint, signature }` NUL-padded to 4096 bytes. The UKI step runs
`ukify build` (`packages/ukify`, systemd's `ukify.py` as a build-time package) with `--linux` from
the kernel package, `--os-release` from the tree, `--uname`, `--phases` from `image/uki.nix`, Secure
Boot signing by `systemd-sbsign` and the PCR 11 policy by `systemd-measure`. The disk step runs
`systemd-repart --empty=create --size=auto --offline=yes --seed=<from the version>` over
`image/repart.nix` rendered to `.conf` files (`repartDefinitions`, `modules/lib/ini.nix`) with the
builder's fields added: the ESP's `CopyFiles=` (systemd-boot as `EFI/BOOT/BOOT<ARCH>.EFI`, the UKI
in `EFI/Linux/`), slot A's labels (`slotLabel`), `CopyBlocks=` and the two UUIDs systemd derives
from the root hash (usr: its first 128 bits, verity: its last). Before repart copies the ESP tree,
`systemd-sbsign` signs systemd-boot with the same db key and certificate as the UKI, and
`EFI/loader/loader.conf` is written from `lib/image/disk.nix`'s `loaderConf` (`timeout 0`,
`editor no`). The B slots are empty, root is made on the machine (`/usr/lib/repart.d/30-root.conf`,
written by `/base`). The ESP is filled offline with mtools (`packages/mtools`). Keys are paths: the
smoke makes throwaway ones in the store (`throwawayKeys`); a release signs with the deployment's
keys (`image/default.nix` `keys`), which never enter the store. Not yet: the verity certificate in
the kernel keyring, a TPM.

Stand-ins the smoke carries on its cmdline, outside `image/uki.nix`: `LD_LIBRARY_PATH=` with the
store directories of the libraries systemd dlopens (the fork's RUNPATH does not name them), and `rw`
(gpt-auto-generator exits 1 in the host, so the remount drop-in it would write is missing). Every
image, not only the smoke, sets the same `LD_LIBRARY_PATH` for services in
`system.conf.d/golconda-dlopen.conf` (`/base`). All three leave with the fork fixes
([Boot: Kernel command line](../design/boot.md#kernel-command-line)).

## Builder constraints

- `systemd-repart` wants a `CopyBlocks=` source in whole sectors; the `-sig.raw` file is padded to
  4096 bytes.
- The UKI cmdline carries `usrhash=<root hash>`, which the generators use to find the `/usr`
  partition; the partition UUIDs of `usr-a` and `usr-a-verity` are the two halves of that hash.
- repart needs no root and no loop device with `--offline=yes`; outside the sandbox it runs the same
  way. The disk file is written straight into the output: it is sparse (two 10 GiB slots), and it
  has no free space for the `root` partition: boot it through a larger overlay (see
  [the walkthrough](walkthrough.md#6-first-boot)), or `truncate` a copy.

## Boot test (`scripts/boot-test`)

The boot test runs the image in QEMU and checks that it reaches `multi-user.target`. It cannot run
inside the Nix sandbox (no KVM), so it is a script, not a derivation. Usage:

```sh
# Build the test image
nix-build -A packages.x86_64-linux.image-smoke-test

# Run the boot test (basic markers)
scripts/boot-test result/disk/disk.raw --keys result/keys --timeout 120

# With Secure Boot (enrols the smoke's throwaway keys; see the note below)
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot

# With TPM (starts swtpm)
scripts/boot-test result/disk/disk.raw --keys result/keys --tpm

# With SSH login test (needs image-smoke-test, not image-smoke)
scripts/boot-test result/disk/disk.raw --keys result/keys --ssh-test
```

`--secure-boot` enrolls the throwaway db key with `virt-fw-vars` (one fixed owner GUID) and boots
`OVMFFull.fd` with `-machine smm=on`: plain `OVMF.fd` has no Secure Boot support. The guest must
report `Secure Boot: enabled` (the `secure-boot-enabled` marker); the same disk with an unsigned
loader on the ESP is refused by firmware, which is the negative control for this check.

The script creates a 40 GiB qcow2 overlay (room for the root partition), copies OVMF vars, passes
the hostname `boot-test` as a credential (`-smbios type=11,...`), and logs the serial console.
Markers checked (each prints PASS/FAIL):

| marker              | what it proves                                 |
| ------------------- | ---------------------------------------------- |
| no-firstboot-prompt | systemd-firstboot did not prompt (masked)      |
| ldconfig-masked     | ldconfig.service did not run                   |
| modprobe-masked     | modprobe@.service did not run                  |
| multi-user-reached  | multi-user.target reached                      |
| sshd-active         | sshd.service started                           |
| hostname-set        | the credential was read (log says `boot-test`) |
| boot-complete       | boot-complete.target reached                   |

With `--ssh-test`, the script uses the test SSH key from `tests/fixtures/snakeoil-ssh` to log in,
then:

| marker            | what it proves                                              |
| ----------------- | ----------------------------------------------------------- |
| ssh-login         | an ssh login with authorized keys works                     |
| varlink-available | `varlinkctl list-interfaces` shows io.systemd.\* interfaces |
| bootctl-list      | `bootctl list` shows the boot entry                         |
| bless-boot        | the entry is marked good (no +N-M counter)                  |

The test SSH keypair is a committed test fixture (`tests/fixtures/snakeoil-ssh*`). The
`image-smoke-test` reads the public key and adds it to `authorizedKeys`. The test script uses the
private key to authenticate. See `tests/fixtures/README.md` for why both keys are committed.
