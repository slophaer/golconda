# Releases

A release is one version of an image: four artifacts, an index, and the names that tie them to the
`/usr` slot they fill. The image builder writes them to `release/` (`lib/image/disk.nu`); systemd
sysupdate reads them from the update source (`image/sysupdate.nix`). This page states the contract:
what a version means, what is stable when the same inputs are rebuilt, and what changes with each
release.

## Version and timestamp

A version is `YYYYMMDD.N`: a real calendar date and the revision `N` inside that day.

| rule         | value                                                                  |
| ------------ | ---------------------------------------------------------------------- |
| year         | 1970 or later                                                          |
| month, day   | a real date; leap years count (`20240229` is valid, `20250229` is not) |
| revision `N` | 0 to 86399, so the timestamp stays inside its date                     |
| timestamp    | `versionToEpoch = epoch(date) + N`, in seconds since 1970-01-01 UTC    |

One grammar enforces this (`lib/version.nix`): the `/system.version` type refuses the value at
evaluation, and `versionToEpoch` (`lib/usr-tree.nix`, re-exported by `lib/image/common.nix`) throws
before a builder runs. Versions are unique and increase: a revision can never share or pass the next
date's timestamp. sysupdate orders versions with `strverscmp`, which this format sorts correctly.
The revision has no leading zero: `20261031.01` is refused (`lib/version.nix`), because two
spellings of one version would share one timestamp, and `ConditionNeedsUpdate=` would not fire
between them.

The timestamp has two uses:

- `mkfs.erofs -T`: every file in the `/usr` image and the filesystem itself carry it. systemd's
  `ConditionNeedsUpdate=/var` compares `/usr`'s mtime with `/var/.updated`, so units with that
  condition run once per version. `/etc` is read-only and has no `.updated`
  ([Updates: Versions](updates.md#versions)).
- The verity salt and filesystem UUID are seeded from the version string (`lib/image/erofs.nix`), so
  the same version rebuilds to the same image.

## Stable across builds, per release

"Stable" means the same inputs (image id, version, `/usr` tree, keys) give the same value. Nix store
paths are content-addressed and Nix sets every file's mtime to 1, so an unchanged build lands on the
same path.

| value                               | stable across builds    | per release                    |
| ----------------------------------- | ----------------------- | ------------------------------ |
| image id, version                   | yes                     | version changes                |
| `versionToEpoch`                    | yes                     | yes                            |
| `/usr` content and its erofs mtime  | yes                     | yes                            |
| verity root hash and the `@u` UUIDs | yes                     | yes                            |
| release file names                  | yes                     | yes                            |
| `SHA256SUMS` bytes and line order   | yes                     | yes                            |
| boot counter `+3-0` at release      | yes                     | starts equal for every release |
| `release/` file mtimes              | yes (Nix sets 1)        | no                             |
| `disk.raw` internal file mtimes     | yes (the version epoch) | yes                            |

The `release/` directory's own file mtimes are 1 (`1970-01-01T00:00:01Z`) in the store. They are not
the release date and must not be used as one: the version, and the erofs timestamps inside the
`/usr` image, carry that. Reproducibility does not depend on mtimes; `SHA256SUMS` hashes content.

## The release directory

`release/` holds four symlinks to the step outputs, the index `SHA256SUMS` and its signature
`SHA256SUMS.gpg` ([The signed index](#the-signed-index)):

| artifact         | release file name                      | installed form                     |
| ---------------- | -------------------------------------- | ---------------------------------- |
| `/usr` image     | `<id>_<version>.usr.<uuid>.raw`        | GPT label `usr_<version>`          |
| verity hash tree | `<id>_<version>.usr-verity.<uuid>.raw` | label `usr-verity_<version>`       |
| verity signature | `<id>_<version>.usr-verity-sig.raw`    | label `usr-verity-sig_<version>`   |
| UKI              | `<id>_<version>.efi`                   | `EFI/Linux/<id>_<version>+3-0.efi` |

`<uuid>` is `@u` in the sysupdate source pattern. The `/usr` file takes the first 128 bits of the
verity root hash as a UUID, the verity file the last 128 bits (systemd's rule for the partition
UUIDs). The signature has no hash-derived UUID: its JSON names the root hash. The two UUIDs are per
release because the root hash is.

`SHA256SUMS` has exactly four lines, in this fixed order:

```text
<sha256 of usr>  <id>_<version>.usr.<uuid>.raw
<sha256 of verity>  <id>_<version>.usr-verity.<uuid>.raw
<sha256 of sig>  <id>_<version>.usr-verity-sig.raw
<sha256 of UKI>  <id>_<version>.efi
```

Each line is the lower-case hex digest, two spaces, and the name, as `sha256sum` writes it. The
index does not list itself. The names are exactly the release names above; the UKI line names the
release file without a boot counter.

## The signed index

`SHA256SUMS.gpg` is a detached binary OpenPGP signature of `SHA256SUMS`, made by the disk step with
the key set's release key (`release/index.key`, Ed25519). Every transfer has `Verify=yes`, so
`systemd-pull` fetches the signature with the index and runs `gpg --verify` against
`/usr/lib/systemd/import-pubring.pgp`, the key's public half in the running image. A payload whose
digest the signed index does not list is never written. The signature time is the version's epoch
(or the key's creation time, if that is later), so a rebuild gives the same bytes.

Why OpenPGP: it is the one signature systemd 262's `systemd-pull` checks, and it checks it only by
running `gpg`. The image therefore carries GnuPG 2.4 and libgcrypt beside OpenSSL, a second crypto
library against [one of each](principles.md). systemd PR
[#44292](https://github.com/systemd/systemd/pull/44292) (UAPI.16 manifests with an inline PKCS#7
signature, checked against x509 certificates) is the way out: once a systemd release has it, the
`db` key's openssl tooling could sign the manifest and GnuPG would leave the image.

What the signature adds: the verity signature and the signed UKI already tie each payload to the
`db` key, so with Secure Boot an attacker on the network could only serve another signed release or
none. Without Secure Boot (`/system.secureBoot = false`) nothing checks a UKI before it runs, so the
signed index is what stops a UKI from someone else.

The running image trusts only the release key it carries, so a release signed with another key
installs nothing (`gpg: Can't check signature: No public key`). A `db` rotation therefore keeps the
release key (`indexKeys`, as it keeps `pcrKeys`). To change the release key itself, take two
releases: one signed with the old key whose image carries the new public key, then the next signed
with the new key. The signature does not stop a replay of an older signed index: sysupdate installs
only versions newer than the running one, and the A/B slots keep the newest two.

`scripts/boot-test --next` reads the index of the next release before it installs anything: four
lines, this order, and every digest against its file. Reordering the lines, renaming a file or
changing a digest fails the test.

## Counters and selection

A release starts its UKI at `+3-0`: three tries left, none done (`image/boot-counting.nix`, the same
value the sysupdate UKI target writes). systemd-boot decrements the counter on each attempt;
`systemd-bless-boot` removes the suffix after `boot-complete.target`. After three failed boots the
entry is `+0-3` and the boot loader prefers the other entry.

sysupdate selects by version, never by counter:

- the source pattern `<id>_@v.efi` matches the release UKI; `@v` is the version.
- the target pattern matches an installed entry with a counter (`<id>_@v+@l-@d.efi`) or a blessed
  one (`<id>_@v.efi`), so both forms are found.
- a partition transfer matches its GPT label, which carries the version (`usr_<version>`), and
  writes that label to the slot it fills; a free slot is `_empty`.
- `InstancesMax=2` keeps two versions, and `ProtectVersion=%A` never overwrites the running one.

The release UKI has no counter because the counter belongs to one installed entry, not to the
artifact. Every install of the same release starts at `+3-0`.

## Related

- [Updates](updates.md): how sysupdate applies a release, and the A/B flow.
- [Image artifacts](../reference/image.md): the builder steps and the file names.
- [Boot](boot.md): boot counting and the boot-complete gate.
