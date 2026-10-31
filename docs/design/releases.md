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

The timestamp has two uses:

- `mkfs.erofs -T`: every file in the `/usr` image and the filesystem itself carry it. systemd's
  `ConditionNeedsUpdate=` compares `/usr`'s mtime with `/etc/.updated`, so first-boot units run once
  per version.
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

`release/` holds four symlinks to the step outputs and the index:

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
index does not list itself, and v1 ships no `SHA256SUMS.gpg` (`Verify=no`). The names are exactly
the release names above; the UKI line names the release file without a boot counter.

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
