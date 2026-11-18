# Image artifacts

The `/usr` tree builder exists (`lib/usr-tree.nix`) and the image chain exists (`lib/image/`):
erofs, verity, initrd, UKI and disk, one derivation each. The `image/` directory holds the
tool-independent definitions they render. [Boot test](boot-test.md) boots the test images in QEMU.

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
`timers.target.wants/systemd-sysupdate-update.timer`, and, unless `/system.updateReboot` is null,
the reboot timer, `timers.target.wants/systemd-sysupdate-reboot.timer`, with an `OnCalendar=`
drop-in and `ExecCondition=/usr/lib/golconda/golconda-update-pending` for its service
([Updates: Activation](../design/updates.md#activation)). systemd 262 renamed
`systemd-sysupdate.timer`/`.service` to `systemd-sysupdate-update.timer`/`.service` and keeps the
old names as aliases. The timer starts `systemd-sysupdate-update.service`, which runs
`systemd-sysupdate update --component-all --cleanup=yes`. The image ships its definitions in
`/usr/lib/sysupdate.d` only. sysupdate.d(5) also reads `/etc/sysupdate.d` and `/run/sysupdate.d`,
and a file there hides the one of the same name in `/usr/lib/sysupdate.d`; the boot test runs the
image's definitions unchanged and serves the release over HTTP
([Boot test: the update test](boot-test.md#the-update-test)).

## Image definitions (`image/`)

| file             | content                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------- |
| `default.nix`    | image identity, the key layout, boot counting; imports the other files                      |
| `os-release.nix` | os-release template (`ID`, `VERSION_ID`, `IMAGE_ID`, `IMAGE_VERSION`, the epoch, …)         |
| `repart.nix`     | systemd-repart partition definitions (ESP, usr-a/b, verity, sig, root)                      |
| `sysupdate.nix`  | systemd-sysupdate transfer definitions (usr, verity, sig, UKI), `Path=` from `updateSource` |
| `uki.nix`        | the UKI cmdline template, the PCR phases, the Secure Boot and PCR signing paths             |

The definitions are data. The composer renders `sysupdate.nix` and the root definition of
`repart.nix`; the image builder renders the rest.

## `/usr` tree (`lib/usr-tree.nix`)

`usrTree { composerOutput; platform; version; buildSystem ? platform.name; sbomDrv ? null; sources; }`
produces a derivation whose output **is** the complete `/usr` directory; `mkSystem` calls it with
the artifacts added ([Configuration](config.md#the-entry-point)):

| path                                     | content                                                                                                                                                                                                           |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix/store/<hash>-*`                     | the runtime closure of `composerOutput.packages`                                                                                                                                                                  |
| `bin/`, `lib/`, `share/`                 | relative symlinks into `nix/store/` (from `links`; kind `farm` expanded); `bin/<name>` for each executable in a package's `exports.json` `bin`, or only its declared `bin` names                                  |
| `sbin`                                   | symlink to `bin`                                                                                                                                                                                                  |
| `lib/systemd/system/<name>`              | unit files (from `composerOutput.units`)                                                                                                                                                                          |
| `lib/sysusers.d/golconda.conf`           | sysusers lines                                                                                                                                                                                                    |
| `lib/tmpfiles.d/golconda.conf`           | tmpfiles lines                                                                                                                                                                                                    |
| `lib/os-release`                         | rendered from `image/os-release.nix` with the version, the architecture and systemd's epoch                                                                                                                       |
| `lib/golconda/packages.json`             | each package with name, version, store path and the fragments that brought it                                                                                                                                     |
| `lib/golconda/{config,schema,sbom}.json` | from `mkSystem`: the normalized options, the schema, the SBOM                                                                                                                                                     |
| `lib/golconda/config.json` fields        | included component or `/system` → option → `{ value?; explicit }`: `explicit` is true when the document set it, false when the default applies (`value` is missing for a computed default); a package is its name |
| `lib/golconda/schema.json` fields        | per option `x-golconda-declaredIn` = `{ module; file }` (file relative to the repo); per module `x-golconda-inputs`, the module paths it reads                                                                    |
| `lib/golconda/attribution.json`          | `{ files; links; units; sysusers; tmpfiles }`, each key (path under `/usr`, unit name, line) → the origins that emitted it: a module path or a build fragment's `name`                                            |
| other `lib/`, `share/`                   | files from `composerOutput.files` (paths under `/usr/`, with their mode)                                                                                                                                          |

Build-time verification: no absolute symlink target; every `dlopen` link resolves and every `farm`
link names a directory; no top-level directory other than `bin`, `lib`, `share`, `nix`, `libexec`
and the `sbin` link. No file has a setuid or setgid bit: the Nix sandbox refuses a `chmod` that sets
one, and the store keeps only the modes `0444` and `0555`.

A Nix store path carries no mtimes (Nix sets them to 1), so the tree itself has none. The erofs step
applies the timestamp derived from the version (`YYYYMMDD.N` → epoch seconds, `toEpoch`) with
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
  names, and a systemd `cpe` would report systemd's CVEs against a data file. Each package says it
  in its `package.nix` (`sourceOf = { package = pkgs.systemd; subpath = "hwdb.d"; }`), and the
  generator writes the purl and the source package's source hash.
- `pedigree.ancestors` names the package a downstream package replaced: its name, version, purl and
  cpe, as the set without the downstream packages describes it. A new package has no `ancestors`.
- `pedigree.patches` lists each patch the build applies, in order, for every component with
  `patches` in its `package.nix` (Golconda's, repkgs' and downstream packages alike); the generator
  writes it. An unpatched package with no replacement has no `pedigree`.

`checks.sbom-schema` validates the test image's SBOM against the CycloneDX 1.5 JSON schema (pinned
in `pins/cyclonedx` and fetched at evaluation, so the check runs offline and builds no image), and
checks that the validator refuses a patch of an unknown type and a missing `bomFormat`. The schema
does not constrain `specVersion`.

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

- `type` is `backport` when the patch's message says it is an upstream commit:
  `(cherry picked from commit <sha>)`, or DEP-3 `Origin: upstream` or `Applied-Upstream:` (a bare
  `Origin: upstream` takes the commit from `git format-patch`'s `From <sha>` line). dosfstools' and
  libtpms' patches are backports. Every other patch is `unofficial`: Golconda's or repkgs' own
  change.
- `diff.url` is, for a backport, the upstream commit (on the package's github or gitlab project);
  else the file, relative to the package's directory (`packages/<name>/` in Golconda,
  `pkgs/<xx>/<name>/` in repkgs; `golconda:origin` says which). `diff.text` is the whole file, so
  the SBOM alone shows what changed; CycloneDX's patch has no hash field.
- `resolves` comes from the patch's own header, when it has one: `name` is the `Subject:` of
  `git format-patch` (without `[PATCH]`) or a DEP-3 `Description:`, else the first paragraph of the
  text before the diff; `references` are the URLs in that text (an `Upstream:` or `Link:` line, for
  example), not those of the backport markers; `type` is `defect` when the subject's summary starts
  with "fix", else `enhancement`. A bare diff has no `resolves`. To say why a patch exists, write it
  at the top of the file: `patch` skips that text.

Roots and transitive packages use the same rule. Only target-set package identities are matched, by
derivation and not by display name; an alias that returns an upstream package keeps its upstream
origin ([Your own packages](config.md#your-own-packages)). `mkSystem` adds `golconda:origin` through
the generator's `extraProperties` hook, and a replacement's `pedigree.ancestors` and `notes` through
its `extraFields` hook; the generator merges them over its own `pedigree`.

`mkSystem.sbom` is the generator's derivation, whose output has `sbom.json`; the `/usr` tree
installs that file. `mkSystem.sbom.bom` is the same document at evaluation time. Neither builds a
package.

## Built today (`lib/image/`)

Nix builds the parts that need no key, each a content-addressed derivation with a nushell builder
(`common.nix`) and repkgs packages only. The signer (`golconda-sign`, `lib/image/sign.nu`) signs and
assembles the rest outside Nix, with the deployment's keys where they lie
([Signing outside Nix](../design/signing.md)). A test image runs the same signer in a derivation
with throwaway keys; `packages.<system>.image-smoke` does so for the system of
`examples/server.toml`, and links `unsigned`, `disk` and `keys`, which `scripts/boot-test` reads.

| step     | where                                          | output                                                                                                                                                                             |
| -------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| initrd   | Nix: `initrdTree { … }`, `initrd { usrTree; }` | `initrd.cpio.zst` ([Boot: the initrd](../design/boot.md#the-initrd))                                                                                                               |
| unsigned | Nix: `manifest { usrTree; initrd; signer; … }` | `manifest.json` (the inputs and every step's parameters), `keys/` (`db.crt`, `pcr.pub`, `index.pgp`), `sign`                                                                       |
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
Boot signing of the UKI by `systemd-sbsign` (`--no-sign-kernel`; the step fails when the `.linux`
section has a certificate table) and the PCR 11 policy by `systemd-measure`. The disk step runs
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
fields that differ. `scripts/verify` builds it beside the image.

The signer is deterministic for the same unsigned output and keys: times, salts, UUIDs and seeds
come from the version, `systemd-sbsign` takes its signing time from `SOURCE_DATE_EPOCH`, and the
signatures (RSA PKCS#1 v1.5, Ed25519) draw no random numbers. `disk.raw` too: systemd-repart passes
`SOURCE_DATE_EPOCH` on to `mkfs.fat`, which writes it as the time of the ESP's volume label entry,
and gives it the volume ID it derives from the ESP's partition UUID (`-i`). dosfstools 4.2 reads no
`SOURCE_DATE_EPOCH`; Golconda carries the upstream commit that adds it
(`packages/dosfstools/source-date-epoch.patch`, dosfstools PR #106, merged after 4.2).
`packages.<system>.disk-reproducible` signs the test image a second time and compares the release
and `disk.raw` byte for byte; `scripts/verify` builds it beside the image.
`packages.<system>.release-without-pk-kek` checks that the key set the test image is signed with has
no `PK.key` and `KEK.key`: `scripts/make-keys` keeps them in `DIR.private`, and the signer copies
the enrolment files that `make-keys` signed. The boot test covers the verity certificate in the
kernel keyring and TPM sealing ([What is proven](../proven.md)).

The smoke, the test image and the production image boot the same command line
([The kernel command line](#the-kernel-command-line)).

## Builder constraints

- `systemd-repart` wants a `CopyBlocks=` source in whole sectors; the `-sig.raw` file is padded to
  4096 bytes.
- The UKI cmdline carries `usrhash=<root hash>`, which the generators use to find the `/usr`
  partition; the partition UUIDs of `usr-a` and `usr-a-verity` are the two halves of that hash.
- repart needs no root and no loop device with `--offline=yes`; outside the sandbox it runs the same
  way. The disk file is written straight into the output: it is sparse (two 10 GiB slots; the test
  images of `nix/default.nix` have two 1 GiB slots), and it has no free space for the `root`
  partition: boot it through a larger overlay, which `scripts/boot-test` does
  ([the walkthrough](walkthrough.md#6-first-boot)), or `truncate` a copy.

## The kernel command line

This section is the only copy of the command line in the documentation. Other pages link here.

`cmdlineTemplate` in `image/uki.nix` is:

```text
usrhash={usrhash} systemd.verity_usr_options=root-hash-signature=base64:{usrhashSig} rw panic=10 softlockup_panic=1 nmi_watchdog=panic hung_task_panic=1 lsm=lockdown,yama,ipe,bpf lockdown=integrity ipe.enforce=1 systemd.imds.import=0 console=tty0 console=ttyS0,115200
```

The UKI step (`lib/image/uki.nu`) fills `{usrhash}` and `{usrhashSig}` and appends `cmdlineExtra`
(empty; for debug flags only). It squeezes repeated spaces and fails the build at 2048 bytes, where
the EFI stub would cut the line after the signature. The result is in the UKI's `.cmdline` section
and in the step's `cmdline` output.

| parameter                                                 | meaning                                                                                                                                                        |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `usrhash={usrhash}`                                       | the verity root hash; the generators derive the two `/usr` partition UUIDs from it, which is how a UKI finds its own slot                                      |
| `systemd.verity_usr_options=root-hash-signature=…`        | the base64 PKCS#7 signature of that hash; the kernel checks it against its built-in db certificate, and IPE trusts only such volumes                           |
| `rw`                                                      | the state partition is the root file system; without it the initrd mounts it read-only and the host key var fails to seal. `/usr` stays read-only by dm-verity |
| `panic=10`                                                | a kernel panic reboots after 10 s, so a release whose kernel panics loses a try ([Boot: Trial boot](../design/boot.md#trial-boot))                             |
| `softlockup_panic=1 nmi_watchdog=panic hung_task_panic=1` | a soft lockup, a hard one (the NMI watchdog: `kernel.hardlockup_panic`) or a task blocked for 120 s panics, so `panic=10` reboots a hang the kernel sees       |
| `lsm=lockdown,yama,ipe,bpf`                               | the LSM stack order (capability is always first)                                                                                                               |
| `lockdown=integrity`                                      | kernel lockdown level: blocks kexec, `/dev/mem` and similar                                                                                                    |
| `ipe.enforce=1`                                           | IPE runs only the initramfs and verity volumes whose signature the kernel verified                                                                             |
| `systemd.imds.import=0`                                   | systemd-imds-generator does not pull `systemd-imds-import.service` into the initrd, which has no network; `/imds` pulls it into the host, on a cloud only      |
| `console=tty0 console=ttyS0,115200`                       | the local console and the serial line; output only, there is no getty                                                                                          |
