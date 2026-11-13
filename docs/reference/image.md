# Image artifacts

The `/usr` tree builder exists (`lib/usr-tree.nix`) and the image chain exists (`lib/image/`):
erofs, verity, initrd, UKI and disk, one derivation each. The `image/` directory holds the
tool-independent definitions they render.

## A release

Names carry the image id and the version; the version sorts with `strverscmp`
([Updates: Versions](../design/updates.md#versions)). The version is a real calendar date and a
revision inside the day (0-86399); the whole contract is in [Releases](../design/releases.md). The
data and hash files also carry the partition UUID systemd derives from the verity root hash (usr:
its first 128 bits, usr-verity: its last); the source pattern reads it with `@u`, and sysupdate
gives the slot it writes that UUID, so the new UKI's `usrhash=` finds the new slot. The signer
writes the release under these names (`release/`, `releaseNames` in `lib/image/disk.nix`).

| artifact         | file name                                                     | sysupdate transfer                                                   |
| ---------------- | ------------------------------------------------------------- | -------------------------------------------------------------------- |
| `/usr` image     | `<id>_<version>.usr.<uuid>.raw`                               | `Type=partition`, `MatchPartitionType=usr`                           |
| verity hash tree | `<id>_<version>.usr-verity.<uuid>.raw`                        | `MatchPartitionType=usr-verity`                                      |
| verity signature | `<id>_<version>.usr-verity-sig.raw`                           | `MatchPartitionType=usr-verity-sig`                                  |
| UKI              | `<id>_<version>.efi` → installed as `<id>_<version>+3-0.efi`  | `Type=regular-file`, `/EFI/Linux` on the ESP (`PathRelativeTo=boot`) |
| index            | `SHA256SUMS`, what a `url-file` source lists                  | —                                                                    |
| index signature  | `SHA256SUMS.gpg`, the release key's signature of `SHA256SUMS` | `Verify=yes` on every transfer                                       |

Each partition transfer finds its slots by GPT label (`image/sysupdate.nix` `slots`, the target
`MatchPattern=`): an installed slot is `usr_<version>`, `usr-verity_<version>` or
`usr-verity-sig_<version>`, a free slot is `_empty`. The signer labels slot A from the same patterns
(`slotLabel`, `lib/image/disk.nix`) and the B slots `_empty` (`image/repart.nix`); sysupdate writes
the formatted pattern as the label of the slot it fills, and keeps the slot's flags: the free usr
slot is read-only without growfs, as slot A is (systemd 262.1 ignores the target's `ReadOnly=` for
partitions). The partition type tells the three transfers apart, so the label carries no image id:
GPT allows 36 characters, the longest prefix (`usr-verity-sig_`) leaves 21 for the version, and a
longer label fails the build.

All transfers use `InstancesMax=2` and `ProtectVersion=%A`. The installed UKI name carries the boot
counter (`+3-0`: three tries left, none done); `systemd-bless-boot` removes the suffix after
`boot-complete.target`.

With `/system.updateSource` set, the composer writes the definitions as
`/usr/lib/sysupdate.d/<n>.transfer` (the suffix systemd wants since 257; `.conf` still loads with a
warning) and enables the update timer with a static link,
`timers.target.wants/systemd-sysupdate-update.timer`. systemd 262 renamed
`systemd-sysupdate.timer`/`.service` to `systemd-sysupdate-update.timer`/`.service` and keeps the
old names as aliases. The timer starts `systemd-sysupdate-update.service`, which runs
`systemd-sysupdate update --component-all --cleanup=yes`. The image ships its definitions in
`/usr/lib/sysupdate.d` only. sysupdate.d(5) also reads `/etc/sysupdate.d` and `/run/sysupdate.d`,
and a file there hides the one of the same name in `/usr/lib/sysupdate.d`; the boot test runs the
image's definitions unchanged and serves the release over HTTP
([The update test](#the-update-test)).

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

| path                                             | content                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix/store/<hash>-*`                             | the runtime closure of `composerOutput.packages`                                                                                                                                                                                                                                                                                                                                        |
| `bin/`, `lib/`, `share/`                         | relative symlinks into `nix/store/` (from `links`; kind `farm` expanded); `bin/<name>` for each executable in a package's `exports.json` `bin`, or only its declared `bin` names                                                                                                                                                                                                        |
| `sbin`                                           | symlink to `bin`                                                                                                                                                                                                                                                                                                                                                                        |
| `lib/systemd/system/<name>`                      | unit files (from `composerOutput.units`)                                                                                                                                                                                                                                                                                                                                                |
| `lib/sysusers.d/golconda.conf`                   | sysusers lines                                                                                                                                                                                                                                                                                                                                                                          |
| `lib/tmpfiles.d/golconda.conf`                   | tmpfiles lines                                                                                                                                                                                                                                                                                                                                                                          |
| `lib/os-release`                                 | rendered from `image/os-release.nix` with the version and the architecture                                                                                                                                                                                                                                                                                                              |
| `lib/golconda/packages.json`                     | each package with name, version, store path and the fragments that brought it                                                                                                                                                                                                                                                                                                           |
| `lib/golconda/{config,schema,modules,sbom}.json` | from `mkSystem`: the normalized options, the schema, the module inventory, the SBOM                                                                                                                                                                                                                                                                                                     |
| `lib/golconda/config.json` fields                | included component or `/system` → option → `{ value?; explicit }`: `explicit` is true when the document set it, false when the default applies (`value` is missing for a computed default); a package is its name                                                                                                                                                                       |
| `lib/golconda/schema.json` fields                | per option `x-golconda-declaredIn` = `{ module; file; line? }` (file relative to the repo; `line` only when the evaluator reports it: iets does, nix does not); per module `x-golconda-inputs`, the module paths it reads                                                                                                                                                               |
| `lib/golconda/modules.json`                      | `{ modules; fragments; packages; }`: `modules` maps every module path → `{ role; inputs; included?; reason?; }` (`role` component, provider, composer or group; for a component `included` and `reason`: `builtin`, `config` or null); `fragments` the names of the build's own fragments (`/image/loader`, `/image/index`); `packages` the downstream packages, name → `{ replaces; }` |
| `lib/golconda/attribution.json`                  | `{ files; links; units; sysusers; tmpfiles }`, each key (path under `/usr`, unit name, line) → the origins that emitted it: a module path or a build fragment's `name`                                                                                                                                                                                                                  |
| other `lib/`, `share/`                           | files from `composerOutput.files` (paths under `/usr/`, with their mode)                                                                                                                                                                                                                                                                                                                |

Build-time verification: no absolute symlink target; every `dlopen` link resolves and every `farm`
link names a directory; no setuid or setgid bit; no top-level directory other than `bin`, `lib`,
`share`, `nix`, `libexec` and the `sbin` link.

A Nix store path carries no mtimes (Nix sets them to 1), so the tree itself has none. The erofs step
applies the timestamp derived from the version (`YYYYMMDD.N` → epoch seconds, `versionToEpoch`) with
`mkfs.erofs -T`.

### Software bill of materials

`lib/golconda/sbom.json` is a CycloneDX 1.5 document for the runtime package closure. It follows
standard identifiers, as the NixOS security tracker does (it links CVEs to packages by name and by
nixpkgs' `meta.identifiers` CPE): a `purl` from each package's `sources.toml`, a `cpe` where the
package declares one, and CycloneDX `pedigree` for a replacement and for a patched package. One
custom property says where a component comes from.

```json
{
  "name": "openssh",
  "version": "0.0.3",
  "purl": "pkg:github/…@0.0.3",
  "cpe": "cpe:2.3:a:example:openssh:0.0.3:*:*:*:*:*:*:*",
  "properties": [ { "name": "golconda:origin", "value": "downstream" } ],
  "pedigree": {
    "ancestors": [ { "type": "application", "name": "openssh", "version": "10.6p1", "purl": "pkg:generic/openssh@10.6p1" } ],
    "notes": "replaced by the downstream package openssh; the original comes from golconda"
  }
}
```

- `golconda:origin` is on every component: `downstream` (a downstream package), `golconda` (one of
  Golconda's `packages/`) or `repkgs` (everything else, the libc and the toolchain included).
- `cpe` comes from `[upstream] cpe` in the package's `sources.toml`, with `{version}` replaced by
  the package's version, modelled on nixpkgs' `meta.identifiers.cpe`; the repkgs SBOM generator
  reads it.
- `hwdb`, `gen-init-cpio` and `ca-bundle` are compiled from another package's source (systemd's
  `hwdb.d`, the kernel's `usr/gen_init_cpio.c`, cacert's roots) and have no `sources.toml`. Their
  `purl` is the source package's, at its pinned version, with a purl subpath (`#hwdb.d`,
  `#usr/gen_init_cpio.c`, `#certifi/cacert.pem`), for example
  `pkg:github/systemd/systemd@262.1#hwdb.d`. They have no `cpe`: they are not the product the NVD
  names, and a systemd `cpe` would report systemd's CVEs against a data file. The table is
  `lib/sbom-sources.nix`; `nix/packages.nix` applies it.
- `pedigree.ancestors` names the package a downstream package replaced: its name, version, purl and
  cpe, as the set without the downstream packages describes it. A new package has no `ancestors`.
- `pedigree.patches` lists each patch the build applies, in order, for every component with
  `patches` in its `package.nix` (Golconda's, repkgs' and downstream packages alike). An unpatched
  package with no replacement has no `pedigree`.

`checks.sbom-schema` validates the test image's SBOM against the CycloneDX 1.5 JSON schema (vendored
in `tests/fixtures/cyclonedx`, so it runs offline and builds no image), and checks that the
validator refuses a patch of an unknown type and a missing `bomFormat`. The schema does not
constrain `specVersion`.

A patch, here the third of systemd's:

```json
{
  "type": "unofficial",
  "diff": {
    "url": "hwdb-imds-hetzner-ssh-keys.patch",
    "text": { "contentType": "text/x-diff", "content": "From df2a0fea… Subject: [PATCH] hwdb: …" }
  },
  "resolves": [ {
    "type": "enhancement",
    "name": "hwdb: import the SSH keys on Hetzner Cloud",
    "references": [ "https://docs.hetzner.cloud/reference/cloud#server-metadata" ]
  } ]
}
```

- `type` is `unofficial`: every patch Golconda and repkgs carry is their own change, not an upstream
  release (`backport`) or an upstream commit (`cherry-pick`).
- `diff.url` is the file, relative to the package's directory (`packages/<name>/` in Golconda,
  `pkgs/<xx>/<name>/` in repkgs; `golconda:origin` says which). `diff.text` is the whole file, so
  the SBOM alone shows what changed; CycloneDX's patch has no hash field.
- `resolves` comes from the patch's own header, when it has one: `name` is the `Subject:` of
  `git format-patch` (without `[PATCH]`), else the first paragraph of the text before the diff;
  `references` are the URLs in that text (an `Upstream:` or `Link:` line, for example); `type` is
  `defect` when the subject's summary starts with "fix", else `enhancement`. A bare diff has no
  `resolves`. To say why a patch exists, write it at the top of the file: `patch` skips that text.

Roots and transitive packages use the same rule. Only target-set package identities are matched, by
derivation and not by display name; an alias that returns an upstream package keeps its upstream
origin ([Your own packages](config.md#your-own-packages)). `mkSystem` adds `golconda:origin` through
the generator's `extraProperties` hook and `pedigree` through its `extraFields` hook
(`lib/sbom-patches.nix` reads the patches from each package's `patches`).

`mkSystem.sbom` is the generator's derivation, whose output has `sbom.json`; the `/usr` tree
installs that file. `mkSystem.sbom.bom` is the same document at evaluation time. Neither builds a
package.

## Built today (`lib/image/`)

Nix builds the parts that need no key, each a content-addressed derivation with a nushell builder
(`common.nix`) and repkgs packages only. The signer (`golconda-sign`, `lib/image/sign.nu`) signs and
assembles the rest outside Nix, with the deployment's keys where they lie
([Trust: Signing outside Nix](../design/trust.md#signing-outside-nix)). A test image runs the same
signer in a derivation with throwaway keys; `packages.<system>.image-smoke` does so for the system
of `examples/server.toml` and writes `proof.txt` (sizes, `veritysetup verify`, the cpio listing,
`ukify inspect`, repart's table).

| step     | where                                          | output                                                                                                                                                                             |
| -------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| initrd   | Nix: `initrdTree { … }`, `initrd { usrTree; }` | `initrd.cpio.zst`, `rdinit` ([Boot: the initrd](../design/boot.md#the-initrd))                                                                                                     |
| unsigned | Nix: `manifest { usrTree; initrd; signer; … }` | `manifest.json` (the inputs and every step's parameters), `keys/` (`db.crt`, `pcr.pub`, `index.pgp`), `sign` (`image-smoke-unsigned`)                                              |
| loader   | signer: `lib/image/loader.nu`                  | `systemd-boot<arch>.efi.signed`, put into the copy of the `/usr` tree and on the ESP ([Boot loader](../design/bootloader.md))                                                      |
| erofs    | signer: `lib/image/erofs.nu`                   | `<id>_<version>.usr.raw`: `mkfs.erofs -zlz4hc -T <epoch> -U <uuid> --all-root --hard-dereference`; epoch and UUID from the version (`erofsParams`)                                 |
| verity   | signer: `lib/image/verity.nu`                  | `<id>_<version>.usr-verity.raw`, the root hash, `<id>_<version>.usr-verity-sig.raw` (`verityParams`)                                                                               |
| uki      | signer: `lib/image/uki.nu`                     | `<id>_<version>+3-0.efi` (`ukiName`, `ukiParams`)                                                                                                                                  |
| disk     | signer: `lib/image/disk.nu`                    | `disk.raw` (sparse, fully allotted: ESP with the signed loader and `loader.conf`, A and B slots, no room for `root`), `disk.json`, `release/` with `SHA256SUMS.gpg` (`diskParams`) |

The verity step: `veritysetup format` with a salt and superblock UUID from the version; the
signature is `openssl smime -sign -nocerts -noattr -binary` over the hex root hash, as
systemd-veritysetup documents; the `-sig.raw` file is systemd's partition content, the JSON
`{ rootHash, certificateFingerprint, signature }` NUL-padded to 4096 bytes. The UKI step runs
`ukify build` (`packages/ukify`, systemd's `ukify.py` as a build-time package) with `--linux` from
the kernel package, `--os-release` from the tree, `--uname`, `--phases` from `image/uki.nix`, Secure
Boot signing by `systemd-sbsign` and the PCR 11 policy by `systemd-measure`. The disk step runs
`systemd-repart --empty=create --size=auto --offline=yes --seed=<from the version>` over
`image/repart.nix` rendered to `.conf` files (`repartDefinitions`, `modules/lib/ini.nix`) with the
builder's fields added: the ESP's `CopyFiles=` (systemd-boot as `EFI/systemd/systemd-boot<arch>.efi`
and `EFI/BOOT/BOOT<ARCH>.EFI`, the UKI in `EFI/Linux/`), slot A's labels (`slotLabel`),
`CopyBlocks=` and the two UUIDs systemd derives from the root hash (usr: its first 128 bits, verity:
its last). The loader on the ESP is the file the signer put into `/usr`. `loader/loader.conf` is
written from `image/loader.nix` (`timeout 0`, `editor no`), the text `/base` installs as
`/usr/lib/golconda/loader.conf`; the signer fails unless the tree's copy is the same. The B slots
are empty, root is made on the machine (`/usr/lib/repart.d/30-root.conf`, written by `/base`).
`release/` holds the four files under their release names (the UKI as `<id>_<version>.efi`) and
`SHA256SUMS`: a directory an HTTP server can publish as the update source. `SHA256SUMS` has four
lines in a fixed order (usr, verity, signature, UKI) and names the release files exactly; it does
not list itself. A file mtime is not the release date: the version epoch lives in the `/usr` erofs
image (and in `disk.raw`'s internal files), not in the release directory's metadata. The ESP is
filled offline with mtools (`packages/mtools`).

The initrd is the same bytes in every build of the same inputs. `lib/image/initrd.nu` writes the
newc cpio with the kernel's own `gen_init_cpio` (`packages/gen-init-cpio`, compiled from the kernel
source that `packages/kernel` pins). It gives the tool a list of the entries in sorted order: each
entry is owned by root and has its mode, and a symlink has its target. `-t 1` gives every entry
mtime 1. The tool numbers the inodes itself (from 721) and writes fixed devices and link counts, so
the bytes depend only on the names, modes, link targets and contents, not on the build directory.
Each file is one entry with its own data; the initrd has no hard links. A symlink's data is its
target with a NUL at the end, as in the kernel's built-in initramfs. A name or target with
whitespace or `$`, or a file that is not a regular file, directory or symlink, fails the build: the
list format cannot hold it. `packages.<system>.initrd-reproducible` builds the test image's initrd a
second time and compares the bytes; when they differ, `tests/initrd/newc-diff.py` names the header
fields that differ. `scripts/verify` builds it after the image.

The signer is deterministic for the same unsigned output and keys: times, salts, UUIDs and seeds
come from the version, `systemd-sbsign` takes its signing time from `SOURCE_DATE_EPOCH`, and the
signatures (RSA PKCS#1 v1.5, Ed25519) draw no random numbers. `disk.raw` too: systemd-repart passes
`SOURCE_DATE_EPOCH` on to `mkfs.fat`, which writes it as the time of the ESP's volume label entry,
and gives it the volume ID it derives from the ESP's partition UUID (`-i`). dosfstools 4.2 reads no
`SOURCE_DATE_EPOCH`; Golconda carries the upstream commit that adds it
(`packages/dosfstools/source-date-epoch.patch`, dosfstools PR #106, merged after 4.2).
`packages.<system>.disk-reproducible` signs the test image a second time and compares the release
and `disk.raw` byte for byte; `scripts/verify` builds it after the image.
`packages.<system>.release-without-pk-kek` signs it with a copy of its key set without
`secureboot/PK.key` and `KEK.key` and compares the same way: the signer copies the enrolment files
that `scripts/make-keys` signed and reads no PK or KEK key. The boot test covers the verity
certificate in the kernel keyring and TPM sealing ([What is proven](../proven.md)).

The smoke, the test image and the production image boot the same command line
([The kernel command line](#the-kernel-command-line)).

## Builder constraints

- `systemd-repart` wants a `CopyBlocks=` source in whole sectors; the `-sig.raw` file is padded to
  4096 bytes.
- The UKI cmdline carries `usrhash=<root hash>`, which the generators use to find the `/usr`
  partition; the partition UUIDs of `usr-a` and `usr-a-verity` are the two halves of that hash.
- repart needs no root and no loop device with `--offline=yes`; outside the sandbox it runs the same
  way. The disk file is written straight into the output: it is sparse (two 10 GiB slots), and it
  has no free space for the `root` partition: boot it through a larger overlay, which
  `scripts/boot-test` does ([the walkthrough](walkthrough.md#6-first-boot)), or `truncate` a copy.

## The kernel command line

This section is the only copy of the command line in the documentation. Other pages link here.

`cmdlineTemplate` in `image/uki.nix` is:

```text
usrhash={usrhash} systemd.verity_usr_options=root-hash-signature=base64:{usrhashSig} rw lsm=lockdown,yama,ipe,bpf lockdown=integrity ipe.enforce=1 systemd.imds.import=0 console=tty0 console=ttyS0,115200
```

The UKI step (`lib/image/uki.nu`) fills `{usrhash}` and `{usrhashSig}`, appends `rdinit=/init`
(`rdinit` in `lib/image/initrd.nu`), and appends `cmdlineExtra` (empty; for debug flags only). It
squeezes repeated spaces and fails the build at 2048 bytes, where the EFI stub would cut the line
after the signature. The result is in the UKI's `.cmdline` section and in the step's `cmdline`
output.

| parameter                                          | meaning                                                                                                                                                   |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `usrhash={usrhash}`                                | the verity root hash; the generators derive the two `/usr` partition UUIDs from it, which is how a UKI finds its own slot                                 |
| `systemd.verity_usr_options=root-hash-signature=…` | the base64 PKCS#7 signature of that hash; the kernel checks it against the platform keyring (firmware db), and IPE trusts only such volumes               |
| `rw`                                               | the root partition carries the state; without it the initrd mounts root read-only and the host key var fails to seal. `/usr` stays read-only by dm-verity |
| `lsm=lockdown,yama,ipe,bpf`                        | the LSM stack order (capability is always first)                                                                                                          |
| `lockdown=integrity`                               | kernel lockdown level: blocks kexec, `/dev/mem` and similar                                                                                               |
| `ipe.enforce=1`                                    | IPE runs only the initramfs and verity volumes whose signature the kernel verified                                                                        |
| `systemd.imds.import=0`                            | systemd-imds-generator does not pull `systemd-imds-import.service` into the initrd, which has no network; `/imds` pulls it into the host, on a cloud only |
| `console=tty0 console=ttyS0,115200`                | the local console and the serial line; output only, there is no getty                                                                                     |
| `rdinit=/init`                                     | what the kernel execs; `/init` links to systemd (`lib/image/initrd.nix` says why a link works before `/proc` exists)                                      |

## Boot test (`scripts/boot-test`)

The boot test runs the image in QEMU and checks that it reaches `multi-user.target`. It cannot run
inside the Nix sandbox (no KVM), so it is a script, not a derivation. Its tools are Golconda's own
packages, built through `scripts/tools.sh` before the run: `qemu-system` (QEMU's x86_64 system
emulator and `qemu-img`), `swtpm`, `virt-firmware` (`virt-fw-vars`), `openssh` and `cpython`, first
on `PATH`; the firmware is the OVMF that comes with `qemu-system` (`share/qemu/edk2-*.fd`): the QEMU
project builds it from edk2-stable202408 and ships it prebuilt in its release tarball, which
`packages/qemu-system/sources.toml` pins by hash. Golconda does not rebuild it, and the project's
own signatures are not checked beyond that hash (`packages/qemu-system/package.nix` has the build
flags and what that trusts); building edk2 from source stays a later step. Usage:

```sh
# Build the test image
nix-build -A packages.x86_64-linux.image-smoke-test

# Run the boot test (basic markers). --secure-boot is required: the image
# enforces IPE and the kernel trusts the verity signature only from the
# platform keyring, which the firmware fills from db.
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --timeout 120

# With TPM (starts swtpm); the db must be enrolled too. The host key checks need --ssh-test.
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test --tpm

# With SSH login test (needs image-smoke-test, not image-smoke)
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test

# Provision by ESP credentials instead of SMBIOS and the image's test key (see below)
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test --esp-creds

# Enrol in one release: push the host certificate and the KRL in the first boot (see below)
nix-build -A packages.x86_64-linux.image-smoke-test-next -o next
scripts/boot-test next/disk/disk.raw --keys next/keys --secure-boot --ssh-test --tpm --enrol

# Update to the next release, the loader update and the recovery paths (needs both images)
nix-build -A packages.x86_64-linux.image-smoke-test-next -o next
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --next next --timeout 480

# With --rotate the next release is signed with a new db key and the variable store is rotated
nix-build -A packages.x86_64-linux.image-smoke-test-rotated -o next-rotated
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --next next-rotated \
  --rotate --timeout 480

# With --fail-health the candidate never passes its health check: three unblessed
# boots, then the old release boots again (see the update test below)
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --next next \
  --fail-health --timeout 480

# Factory reset: the reset request, the reset boot, and the state checks (two boots)
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test \
  --factory-reset --timeout 480
```

`--next` pushes admin vars with `golconda vars`, as an operator does: build it
(`nix-build -A packages.x86_64-linux.golconda-cli`) and name its binary in `BOOT_TEST_GOLCONDA`, and
put `age` and `age-keygen` (`packages.x86_64-linux.age`) and `ssh-keygen` on PATH.
`BOOT_TEST_SSH_PORT` sets the host port for the guest's sshd; without it the harness takes the first
free port from 10022 up and prints it (`ssh: 127.0.0.1:10023 -> guest 22`). `BOOT_TEST_HTTP_PORT`
sets the port the guest uses for the release server of `--next` (default 8074): it is an address
inside the guest's network, not a host port. The test image's `updateSource` names
`169.254.169.2:8074`, so another port needs an image built with that `updateSource`.

With `--ssh-test` the harness also serves two HTTPS sites to the guest, `169.254.169.5:443` and
`169.254.169.6:443`: QEMU guestfwds to a TLS server over stdio (`scripts/boot-test-tls.sh`, python's
`ssl`), with the server certificates of two test CAs (`tests/fixtures/ca-store`). The test image
names those CAs in `/trust` (the first as an anchor, the second as an anchor and, by its SHA-256
fingerprint, distrusted), and `ca-store-links`, `ca-bundle-content`, `tls-anchor-trusted` and
`tls-distrusted-refused` check the guest's bundle and the fetch with `systemd-pull`. No host port
opens.

Every mode runs on QEMU's user network `169.254.169.0/24` (`-netdev user,net=`), not the default
`10.0.2.0/24`: `--imds` needs Hetzner's metadata address, `169.254.169.254`, on the guest's link.
The network's gateway, `169.254.169.2` (QEMU's "host", where `10.0.2.2` is on the default network),
is the update source the test images name. systemd's IMDS lock (`imds-network=locked`) is one
`prohibit` route for the endpoint address alone, so the rest of the network, the update server
included, stays reachable; `imds-endpoint-locked` and the update markers prove both in one run
(`--imds --next`).

`scripts/verify --boot-set ARGS` (repeat it) builds the image once and boots a list of flag sets at
the same time, each with its own log. `@next` in the flags stands for the next release's image:
`--next @next` makes verify build `<image>-next` as well (`image-smoke-test-next` for
`image-smoke-test`, `image-smoke-test-nosb-next` for `--image image-smoke-test-nosb`; out-link
`result-verify-next`), and `golconda-cli` and `age` for `--next`'s admin vars, and put their paths
in the flags, in `BOOT_TEST_GOLCONDA` and on `PATH`. A set that starts with the word `@image=ATTR`
boots `packages.<system>.ATTR` instead of `--image`'s image, and its `@next` is `ATTR-next`: verify
builds each image the sets name once (out-link `result-verify-ATTR`, step `image:ATTR`; the next
image `result-verify-ATTR-next`, step `image-next:ATTR`), so one run boots the Secure Boot sets and
`@image=image-smoke-test-nosb` sets together. Its summary has one line per set, with the image,
`PASS boot[N] 59s @image=ATTR FLAGS` or `FAIL(CODE) boot[N] 59s @image=ATTR FLAGS (log PATH)`,
followed by the checks that passed, `  passed boot[N] (COUNT): NAME …`, so a check that stops
running shows without a log. The exit status is non-zero when any set fails. A set that passes
removes its log, as `scripts/boot-test` removes the work directory of a run that passes; a set that
fails keeps both.

The work directory of every run is `run.XXXXXX` under `$BOOT_TEST_CACHE` (default
`${XDG_CACHE_HOME:-$HOME/.cache}/golconda-boot-test`), not under `/tmp`, which a queue task or a
reboot may drop. A run that passes removes its directory; a run that fails keeps it, with the serial
logs, and prints the path. `scripts/verify --boot-set` puts the logs of the sets that fail in
`verify.XXXXXX` in the same directory, and removes its own directories older than 7 days.

Several runs can share one host and one image. Each has its own work directory, its own swtpm socket
and state, firmware variables, disk overlay, keys, ssh port and update server. A run claims its ssh
port with a `flock` on `$BOOT_TEST_PORT_LOCKS/PORT` (default
`$XDG_RUNTIME_DIR/boot-test-ports-UID`), so two runs that start together never pick the same one,
and the lock goes away when the run dies. Each run needs about 2 GiB of RAM and 2 CPUs.
`BOOT_TEST_STORE_ROOT` names the root of a chroot store (`--store 'local?root=DIR'`): the harness
follows a `/nix/store` symlink under it.

The image enforces IPE (`ipe.enforce=1`): `/usr` executes only from a dm-verity mapping whose root
hash signature the kernel verified. The signature is signed with the Secure Boot db key and its
certificate reaches the kernel through the platform keyring, which the firmware loads from db. A
boot without the db enrolled stops at switch-root with `Failed to execute /sbin/init`; this is the
negative control for the mechanism, not a harness defect.

`--esp-creds` (with `--ssh-test`) provisions through the ESP. The harness copies the disk into its
work directory, generates an ssh key pair there, and runs `scripts/provision-esp` on the copy with
`--hostname esp-test --authorized-keys <key>.pub`. It passes no SMBIOS host name. The ssh checks log
in with the generated key, and `hostname` must print `esp-test`.
`scripts/provision-esp <disk.raw> [--hostname NAME] [--authorized-keys FILE] [--credential NAME=FILE]...`
writes each value as a null-key `loader/credentials/NAME.cred` on the ESP of the disk, in place, and
lists the directory. It finds the ESP in the GPT and refuses a path in `/nix/store`. With
`--secure-boot` and `--tpm` together the guest refuses these credentials
([Bootstrap credentials](../design/boot.md#bootstrap-credentials)), so that run fails.
`BOOT_TEST_ESP_NO_KEY=1` leaves the key out of the ESP: the login must then fail.

`--imds` (with `--ssh-test`, not with `--esp-creds`; with `--next` the update test runs after the
`--imds` checks) fakes Hetzner Cloud for `/imds`, which the test image has, and the guest finds the
endpoint as it does on Hetzner: by hwdb alone (systemd's entry with `packages/systemd`'s patch),
with no `imds.*` credential. QEMU gets `-smbios type=0,vendor=Hetzner`, so `40-imds.hwdb` matches.
Its user network is `169.254.169.0/24` (`-netdev user,net=`, as in every mode), so `169.254.169.254`
is on the guest's link, as imdsd's route to it (`Scope=link`) needs. A QEMU `guestfwd` serves port
80 of `169.254.169.254` from a stdio HTTP server in the work directory, in Hetzner's layout:
`/hetzner/v1/metadata/hostname` (`imds-test`), `region`, `availability-zone`, `public-ipv4`,
`public-keys` (a JSON array of two key pairs the harness makes, with a bad entry between them: two
keys in one string) and `/hetzner/v1/userdata`. It passes no SMBIOS host name. The user data lists
the credentials `imds-canary`, `login.motd`, `ssh.authorized_keys.root` (a third key pair, which the
import skips) and `network.network.60-imds-ipv6`: the static address `2001:db8:5eed::1/64`,
`IPv6AcceptRA=no` and `UseHostname=no`, and nothing of the IMDS lock of `85-imds-early.network`,
which the file replaces. QEMU's router advertisements name only `fec0::/64`, so no other route gives
that address. QEMU's DHCP server offers the host name `dhcp-test` (`-netdev user,hostname=`).

`--enrol` (with `--ssh-test`; not with `--next`, `--esp-creds`, `--imds` or `--factory-reset`) is
the one-release enrolment of [Trust: Enrolment](../design/trust.md#enrolment). Boot it on
`image-smoke-test-next`, which has `hostCertificate` and `revokedKeys` on from its first boot. The
harness makes a second plain key, the bootstrap key, and passes it as the SMBIOS credential
`ssh.authorized_keys.root` (`io.systemd.credential.binary:`, base64). Before anything is pushed, it
logs in with that key and checks that a good certificate is refused and that sshd's journal names
the revocation list; then it pushes as `--next` does and runs the certificate checks in the same
boot. The KRL names neither plain key, so their refusal after the push is the enrolment's. From the
push on, the harness logs in with its own certificate, `cert-admin` (serial 4), after the test key.
It needs the tools of `--next` (`golconda`, `age`).

`--secure-boot` enrolls the throwaway db key with `virt-fw-vars` (one fixed owner GUID) and boots
OVMF's Secure Boot build (`edk2-x86_64-secure-code.fd`: Secure Boot, SMM and TPM 2.0, 3.5 MB of
code) with `-machine smm=on`; `--tpm` takes that build too. A boot with neither takes the plain
build (`edk2-x86_64-code.fd`), which has no Secure Boot support. Both pair with the empty variable
store `edk2-i386-vars.fd` (528 KB: together the 4 MB flash). The guest must report
`Secure Boot: enabled` (the `secure-boot-enabled` marker); the same disk with an unsigned loader on
the ESP is refused by firmware, which is the negative control for this check.

`--secure-boot --auto-enrol` (with `--ssh-test`) enrols nothing: OVMF starts with its empty variable
store, in Setup Mode, and QEMU may reboot. systemd-boot must enrol the ESP's `loader/keys/auto` and
reset ([Boot loader: Enrolment](../design/bootloader.md#enrolment)). `auto-enrolled` reads its
message in the serial log; `pk-enrolled`, `kek-enrolled`, `db-enrolled` and `dbx-enrolled` read the
variables from efivarfs over ssh: `PK` is the key set's `secureboot/PK.crt`; `KEK` holds its
`KEK.crt` and Microsoft's KEK CA 2011 and KEK 2K CA 2023; `db` its `db.crt` and the Microsoft UEFI
CA 2011, UEFI CA 2023 and Option ROM UEFI CA 2023, and neither Windows CA; `dbx` is Microsoft's list
(the files of `packages/secureboot-objects`). With `--no-microsoft-keys`, for
`image-smoke-test-own-keys`, `KEK` and `db` hold none of Microsoft's certificates and `dbx` is
empty. Then the ssh battery runs as with `--secure-boot`. Last, `no-reenrol`: the harness writes the
enrolment files back to `loader/keys/auto` over ssh, stops QEMU, empties the variable store (Setup
Mode again, as after a CMOS clear) and boots: the serial log must have no enrolment message, the
kernel's line, and `Secure boot disabled`. That boot stops at switch-root, as any boot without the
`db` does, so it is the run's last.

The script creates a 40 GiB qcow2 overlay (room for the root partition), copies the OVMF variable
store, passes the host name `boot-test` as a credential (`-smbios type=11,...`, not with
`--esp-creds` or `--imds`), and logs the serial console to a file. QEMU runs with `-display none`
and no monitor or QMP socket: the harness reaches the guest through the serial log and ssh, and
nothing else. QEMU runs with `-no-reboot` unless `--tpm`, `--next`, `--factory-reset` or
`--auto-enrol` is given, because those reboot the guest.

### The markers

Each check prints `PASS: <marker>` or `FAIL: <marker>`. The script and its parts
(`scripts/boot-test-*.sh`, listed in the header of `scripts/boot-test`) are the source of truth;
this list was made from it at commit `dbafac0`. To list the names the script prints:

```sh
grep -ho 'verdict "[a-z0-9-]*\|PASS: [a-z0-9-]*' scripts/boot-test scripts/boot-test-*.sh | sed 's/verdict "//;s/PASS: //' | sort -u
```

Always (read from the serial log; `check_markers`):

| marker                | what it proves                                                        |
| --------------------- | --------------------------------------------------------------------- |
| `multi-user-reached`  | `multi-user.target` was reached                                       |
| `sshd-active`         | sshd started                                                          |
| `var-sshd-hostkey`    | the host key var finished, so the root was writable when the unit ran |
| `boot-complete`       | `boot-complete.target` was reached                                    |
| `no-firstboot-prompt` | no "Please enter" prompt appeared (see the limit below)               |

`no-firstboot-prompt` passes when the log has no prompt. The script prints `INFO` and counts a pass
when firstboot left no trace in the log, so this marker is absence of evidence, not proof that
firstboot ran.

With `--ssh-test` (the harness logs in as root with `tests/fixtures/snakeoil-ssh`):

| marker                         | what it proves                                                                                                                                                                |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ssh-login`                    | an ssh login with the test key works                                                                                                                                          |
| `hostname`                     | `hostname` prints `boot-test`: PID 1 applied the `system.hostname` credential (not with `--imds`)                                                                             |
| `imds-import-inactive`         | without `--imds`: no cloud in DMI, so `systemd-imds-early-network.service` and `systemd-imds-import.service` never started                                                    |
| `esp-authorized-keys`          | with `--esp-creds`: `/root/.ssh/authorized_keys` holds the generated key                                                                                                      |
| `no-failed-units`              | `systemctl --failed` lists no unit                                                                                                                                            |
| `varlinkctl-list-interfaces`   | `io.systemd.Manager` answers on its varlink socket                                                                                                                            |
| `secure-boot-enabled`          | `bootctl status` says `Secure Boot: enabled` (with `--secure-boot`)                                                                                                           |
| `hwdb`                         | `/usr/lib/udev/hwdb.bin` answers for DMI, PCI and USB; none in `/etc`                                                                                                         |
| `clock-not-reset`              | this boot's journal (`journalctl -b`) has no "further ahead than" reset message from PID 1, and no entry is older than the year of systemd's built-in epoch (`time-epoch`)    |
| `ipe-denies-copy`              | a copy of `/usr/bin/sh` in `/var/tmp` gets EACCES, and IPE logs the denial                                                                                                    |
| `units-composed-only`          | `/etc/systemd/system` holds no link, and every unit systemctl calls enabled has a static link in a `.wants`, `.requires` or `.upholds` directory of `/usr/lib/systemd/system` |
| `no-sysext`                    | no unit file and no program of `systemd-sysext` or `systemd-confext`                                                                                                          |
| `cert-login`                   | a certificate from the test user CA (`tests/fixtures/snakeoil-user-ca`) logs in as root for the principal `boot-test-admin`                                                   |
| `cert-wrong-principal-refused` | a certificate for another principal is refused                                                                                                                                |
| `index-keyring`                | `/usr/lib/systemd/import-pubring.pgp` is the key set's `release/index.pgp`                                                                                                    |

With `--imds` (instead of `hostname`):

| marker                     | what it proves                                                                                                                                                                                 |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `imds-hostname`            | the generator pulled `systemd-imds-import.service` in, it succeeded, and `hostname` and `/etc/hostname` are `imds-test` (`firstboot.hostname`)                                                 |
| `imds-hetzner-layout`      | the guest has no `imds.*` credential; the server answered `GET /hetzner/v1/metadata/hostname` and `GET /hetzner/v1/userdata` with 200, and nothing 404                                         |
| `imds-ssh-keys-json`       | both keys of the JSON array `/metadata/public-keys` log in as root; a bad entry between them is skipped with a warning; `authorized_keys` is 0600                                              |
| `imds-ssh-key-precedence`  | the import skips the user data's `ssh.authorized_keys.root` (the metadata's keys came first); its key does not log in                                                                          |
| `imds-userdata-credential` | `/run/credstore/imds-canary` holds its value, and tmpfiles wrote `login.motd` to `/etc/motd.d`                                                                                                 |
| `imds-ipv6`                | the link uses `/run/systemd/network/60-imds-ipv6.network` from the user data, and has `2001:db8:5eed::1`                                                                                       |
| `imds-endpoint-locked`     | with that file (no lock in it), `systemd-pull` gets no answer from `169.254.169.254` and the server sees no request; `systemd-imds --cache=no` (through imdsd) gets one                        |
| `imds-lock-endpoints`      | with and without a cloud in DMI, `ssh` (a root process that is not imdsd) gets "Permission denied" (`EACCES` from the prohibit rule on `lo`) at every IPv4 and IPv6 endpoint of `40-imds.hwdb` |
| `imds-dhcp-hostname`       | the lease holds `dhcp-test`, `/imds`'s `UseHostname=no` drop-in reaches `85-imds-early.network`, and after `networkctl renew` the host name is `imds-test`                                     |
| `imds-no-ordering-cycle`   | the journal has no ordering cycle: the import runs after `network-online.target` and before `sysinit.target`                                                                                   |

The loader checks ([Boot loader](../design/bootloader.md)) run on the first boot, again after an
update, and after a rotation:

| marker                  | what it proves                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------- |
| `loader-update-ran`     | `golconda-loader-update.service` ran after bless-boot on a counted boot                 |
| `loader-update-not-run` | it did not run on a blessed boot (used after a rotation)                                |
| `loader-matches-usr`    | `EFI/systemd/systemd-bootx64.efi` and `EFI/BOOT/BOOTX64.EFI` are `/usr`'s signed loader |
| `loader-conf-in-effect` | `bootctl status` reads `loader/loader.conf`, and it is `/usr/lib/golconda/loader.conf`  |
| `enrol-disarmed`        | that `loader.conf` says `secure-boot-enroll off`: the first disk's `force` is replaced  |
| `enrol-keys-removed`    | with `--secure-boot`: the ESP has no `loader/keys/auto`                                 |
| `boot-update-off`       | `systemd-boot-update.service` never started: nothing enables it                         |

With `--tpm` (and `--ssh-test`):

| marker                         | what it proves                                                                                                                                                                                              |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hostkey-sealed-with-tpm2`     | the header of `sshd-hostkey.key` says TPM2 and the signed PCR policy                                                                                                                                        |
| `ssh-after-reboot`             | the guest came back with a new boot id                                                                                                                                                                      |
| `hostkey-unchanged`            | sshd presents the first boot's host key, the credential has the first boot's bytes (not re-sealed), sshd runs; after the reboot, after an update (`--next`) and after the fallback (`--next --fail-health`) |
| `no-failed-units-after-reboot` | no failed unit on the second boot                                                                                                                                                                           |
| `clock-not-reset-after-reboot` | `clock-not-reset` on the second boot's journal                                                                                                                                                              |

With `--next DIR` ([The update test](#the-update-test)):

| marker                                                                 | what it proves                                                                                                                                              |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `release-index`                                                        | `SHA256SUMS` has four lines in the fixed order, the digests match, none lists itself                                                                        |
| `http-source`                                                          | the guest's own `10-usr.transfer` has `Type=url-file` and `Path=http://169.254.169.2:<port>/`                                                               |
| `http-fetch`                                                           | the sysupdate journal names the release over `http`, so the guest fetched it, not a local file                                                              |
| `sysupdate-installed`                                                  | `systemd-sysupdate-update.service` installed the release                                                                                                    |
| `sysupdate-refused`                                                    | with `--tamper-index`: the service failed, its journal names the index signature and no install, and the next release is on no partition or ESP entry       |
| `boots-old`                                                            | with `--tamper-index`, after the reboot `IMAGE_VERSION` is still the old version                                                                            |
| `no-failed-units-after-refused-update`                                 | with `--tamper-index`, the system has no failed unit after the refused update                                                                               |
| `clock-not-reset-after-refused-update`                                 | with `--tamper-index`, `clock-not-reset` on the journal of the boot after the refused update                                                                |
| `hostkey-fingerprint-on-console`                                       | the key `golconda vars pub` reads has the fingerprint the first boot wrote on the console                                                                   |
| `admin-vars-pushed`                                                    | before the update, `golconda vars` stored and pushed the host certificate (the guest's host key signed by `snakeoil-host-ca`) and a KRL, and restarted sshd |
| `admin-vars-sealed`                                                    | `golconda vars list` says both are stored and sealed                                                                                                        |
| `host-cert-presented`                                                  | the next release presents the host certificate to a strict `@cert-authority` known_hosts                                                                    |
| `cert-login-after-update`, `cert-revoked-refused`                      | the good certificate logs in; the one the KRL names is refused                                                                                              |
| `krl-pushed-again`, `krl-rotated`                                      | a second KRL, pushed while the release runs, refuses the good certificate too                                                                               |
| `boots-next`                                                           | after the reboot `IMAGE_VERSION` is the new version                                                                                                         |
| `units-composed-only-after-update`, `no-sysext-after-update`           | `units-composed-only` and `no-sysext` on the updated release; with `--fail-health`, `-after-fallback` on the old release                                    |
| `no-failed-units-after-update`                                         | the updated system has no failed unit                                                                                                                       |
| `clock-not-reset-after-update`                                         | `clock-not-reset` on the updated release's first boot                                                                                                       |
| `clock-not-reset-after-fallback`                                       | with `--fail-health`, `clock-not-reset` on the fallback boot of the old release                                                                             |
| `hwdb-after-update`                                                    | the updated release's `/usr/lib/udev/hwdb.bin` answers for DMI, PCI and USB; none in `/etc`                                                                 |
| `loader-replaced`                                                      | when the loader bytes differ, the new loader is on the ESP and the old one is `systemd-boot-fallbackx64.efi`                                                |
| `bootctl-list-both-slots`                                              | `bootctl list` shows the entries of both versions                                                                                                           |
| `loader-reinstall`                                                     | a damaged `BOOTX64.EFI` is reinstalled by `golconda-loader-update`                                                                                          |
| `set-oneshot-other-slot`, `other-slot-keeps-loader`, `oneshot-is-once` | `bootctl set-oneshot` boots the other slot once and installs nothing                                                                                        |
| `set-default-other-slot`, `set-default-cleared`                        | `bootctl set-default` boots the other slot until it is cleared                                                                                              |
| `reboot-to-firmware`                                                   | `bootctl reboot-to-firmware` reaches OVMF's boot menu                                                                                                       |

With `--enrol` (and `--ssh-test`; instead of `cert-login`):

| marker                                                                     | what it proves                                                                                                                                                         |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bootstrap-key-login`                                                      | the bootstrap key from the SMBIOS credential logs in before anything is pushed                                                                                         |
| `cert-refused-before-enrol`                                                | a good certificate is refused, and sshd's journal says the revocation list refused it                                                                                  |
| `enrol-wrong-fingerprint-refused`                                          | `golconda vars enrol` with a fingerprint that is not the console's refuses, and nothing is stored or sealed                                                            |
| `hostkey-fingerprint-on-console`, `admin-vars-pushed`, `admin-vars-sealed` | `golconda vars enrol` with the console's fingerprint signs the host key, stores and pushes the certificate and a KRL, in the first boot of the release that reads them |
| `host-cert-presented`, `cert-login-after-enrol`, `cert-revoked-refused`    | the same boot presents the host certificate, takes the good certificate, refuses the revoked one                                                                       |
| `bootstrap-key-refused-after-enrol`                                        | the bootstrap key and the image's test key are refused; the KRL names neither                                                                                          |
| `krl-pushed-again`, `krl-rotated`                                          | a second KRL takes effect, as with `--next`                                                                                                                            |
| `enrol-one-release`                                                        | all of it ran in the first boot: the boot id and the version did not change                                                                                            |
| `host-cert-presented-after-reboot`, `cert-revoked-refused-after-reboot`    | with `--tpm`: after the reboot the sealed certificate and the rotated KRL are in force                                                                                 |
| `bootstrap-key-refused-after-reboot`                                       | with `--tpm`: after the reboot plain keys are still refused                                                                                                            |

With `--rotate`:

| marker                                                       | what it proves                                                                   |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `loader-signed-again`                                        | a new db key gives new loader bytes                                              |
| `boots-after-rotation`, `secure-boot-enabled-after-rotation` | the guest boots the new chain with db = the new certificate alone                |
| `kernel-db-rotated`                                          | the kernel loaded only the new db certificate                                    |
| `no-failed-units-after-rotation`                             | no failed unit after the rotation                                                |
| `clock-not-reset-after-rotate`                               | `clock-not-reset` on the journal of the boot after the rotation                  |
| `old-loader-refused`                                         | the original disk under the rotated store gets "Access Denied"; no kernel starts |

With `--factory-reset --ssh-test` ([The factory reset test](#the-factory-reset-test)):

| marker                     | what it proves                                                                            |
| -------------------------- | ----------------------------------------------------------------------------------------- |
| `factory-reset-test-image` | `/usr/lib/os-release` says `IMAGE_ID=boot-test`, so the reset runs on the test image only |
| `factory-reset-before`     | `/etc/machine-id`, `IMAGE_VERSION` and `bootctl list` were readable before the reset      |
| `state-marker-written`     | the marker in `/etc` is readable before the request                                       |
| `state-gone`               | the guest says the marker is absent after the reset boot                                  |
| `machine-id-new`           | `/etc/machine-id` is non-empty and differs from the id before the reset                   |
| `first-boot-rerun`         | the reset boot's serial log has `systemd-firstboot.service` finishing                     |
| `multi-user-after-reset`   | the reset boot reached `multi-user.target`                                                |
| `slots-kept`               | `bootctl list` entries (ignoring the boot counter) and `IMAGE_VERSION` are unchanged      |

The test SSH keypair is a committed test fixture (`tests/fixtures/snakeoil-ssh*`). The
`image-smoke-test` reads the public key and adds it to `authorizedKeys`. See
`tests/fixtures/README.md` for why both keys are committed.

### The update test

`scripts/boot-test … --next DIR` runs the whole A/B update. No step is manual and the guest need not
be held. `DIR` is a built release (`DIR/disk/release`, `DIR/keys`). The harness:

1. checks the release's `SHA256SUMS` on the host (`release-index`);
1. resolves the release's symlinks into `$WORKDIR/http` (`cp -L`) and writes `$WORKDIR/serve-http`,
   an HTTP server over stdin and stdout (Python's `SimpleHTTPRequestHandler`), which it first asks
   for `SHA256SUMS` on the host. QEMU's user network forwards the guest's connections to
   `169.254.169.2:8074` to that command (`guestfwd=tcp:169.254.169.2:8074-cmd:$WORKDIR/serve-http`),
   one process per connection, so the image's `http://169.254.169.2:8074/` reaches this run's server
   and no host port is opened;
1. checks that the guest's own `/usr/lib/sysupdate.d/10-usr.transfer` has `Type=url-file` and
   `Path=http://169.254.169.2:8074/` (`http-source`). No definition is rewritten;
1. starts `systemd-sysupdate-update.service` and waits for it. The journal's
   `Successfully installed 'http://…'` line is `http-fetch`; the service's exit status is
   `sysupdate-installed`. sysupdate fetches `SHA256SUMS` and the four artifacts over HTTP, then
   writes the B slots and `EFI/Linux/<id>_<version>+3-0.efi`;
1. reboots and checks `boots-next`, `units-composed-only-after-update`,
   `no-failed-units-after-update`, `clock-not-reset-after-update`, `hwdb-after-update` and the
   loader markers (the new release installed its loader on its first good boot and kept the previous
   one as `systemd-boot-fallbackx64.efi`);
1. runs the recovery paths: `bootctl list` shows both slots, a damaged `BOOTX64.EFI` is reinstalled
   by `golconda-loader-update`, `bootctl set-oneshot` and `bootctl set-default` boot the other slot
   and back, and `bootctl reboot-to-firmware` reaches OVMF's boot menu.

`image-smoke-test` sets `updateSource = "http://169.254.169.2:8074/"` (the gateway of the test's
QEMU user network, `169.254.169.0/24`, is the host). The harness serves `DIR/disk/release` at that
address through the guest forward above, so the image's own `url-file` definitions fetch the release
over HTTP; it rewrites nothing under `/run`. `BOOT_TEST_HTTP_PORT` changes the port the guest
connects to; the image's `updateSource` must then name the same port. There is no server process to
stop: QEMU starts the command for each connection and it ends with the connection. The requests are
logged in `$WORKDIR/http.log`.

`--next DIR --tamper-index` is the negative control of the signed index, and it passes when the
update is refused. The server sends `SHA256SUMS` with one byte more than its signature
(`SHA256SUMS.gpg`) covers. The run checks `index-signed` (the guest fetched the signature),
`sysupdate-refused`, and, after a reboot, `boots-old`, `hostkey-unchanged` (with `--tpm`),
`no-failed-units-after-refused-update` and `clock-not-reset-after-refused-update`. It leaves out
`http-fetch`, `sysupdate-installed` and every check that needs the installed release, and it does
not combine with `--rotate` or `--fail-health`. An update that installs, or any other failure, fails
the run.

The next release comes from `packages.<system>.image-smoke-test-next` (version `20261031.2`, the
same keys as the first release; [Outputs](outputs.md)), and `--next` takes its path. The firmware
already holds that release's keys, so no `--rotate` is needed.

`--rotate` takes `image-smoke-test-rotated` instead (`20261031.2`, signed with a second db key). The
harness enrols that certificate beside the old one before the first boot. After the checks it stops
QEMU, sets db to the new certificate alone, adds the old one to dbx (`virt-fw-vars`), boots again,
checks that the kernel loaded only the new db certificate, and boots the original disk under the
rotated store, which firmware must refuse.

`--next DIR --fail-health` proves the fallback instead of the good update boot. It masks a health
unit (`/etc/systemd/system/golconda-health-network.service` → `/dev/null`), so
`boot-complete.target` cannot be reached and the candidate is never blessed. It then reboots three
times and checks after each one that the counter fell (`tries: 2 left; 1 done`, then
`1 left; 2 done`, then `0 left; 3 done`), that `boot-complete.target` is inactive and that the
loader update did not run. It lifts the mask and checks the fourth boot: the previous release runs,
the candidate is at `tries: 0 left; 3 done`, the old entry is the one systemd-boot selected, and PID
1 kept the clock (`clock-not-reset-after-fallback`). A mask keeps every boot clean and ssh
reachable, so the counter can be read after each one; cutting the link would need a QMP `set_link`
call and a hard reset. `--fail-health` and `--rotate` are alternatives, and `--fail-health` skips
the loader and recovery checks, because no boot of the candidate is blessed.

What this test does not prove:

- **The production transfer.** The test serves a release over plain `http` from the host. It proves
  the image's `url-file` source and the HTTP fetch, but not HTTPS, a real update server with
  redirects or authentication, the update timer, or a machine whose network is not QEMU's user-mode
  network.

### The factory reset test

`scripts/boot-test … --factory-reset --ssh-test` checks the state reset on the test image. It is a
boot of its own: do not combine it with `--next`, and give a `--timeout` large enough for two boots
(such as 480). The harness:

1. checks that `/usr/lib/os-release` says `IMAGE_ID=boot-test`, writes
   `/etc/boot-test-factory-reset`, and reads `/etc/machine-id`, `IMAGE_VERSION` and `bootctl list`;
1. runs `systemctl start factory-reset.target` in the guest. The target sets the
   `FactoryResetRequest` EFI variable, and `systemd-factory-reset-reboot.service` reboots
   (systemd-factory-reset(8), [Updates: Factory reset](../design/updates.md#factory-reset));
1. waits for a login with a new boot id, then checks `state-gone`, `machine-id-new`,
   `first-boot-rerun`, `multi-user-after-reset` and `slots-kept`, and prints the last 100 lines of
   the reset boot's serial log.

`slots-kept` compares the `id:` lines of `bootctl list`, with the boot counter removed, and
`IMAGE_VERSION` before and after the reset: systemd-repart rewrites the root partition only, so the
ESP and the `/usr` slots stay. `state-gone` asks the guest to print `absent` for the marker file, so
an ssh failure cannot count as a pass.

What this test does not prove: a reset on a machine with an update installed (the test image has one
`/usr` slot), the TPM clear and sealed credentials, or the console path on a machine whose ssh is
down. Those stay manual ([Recovery: State reset](../design/recovery.md#state-reset)).
