# Image artifacts

*(Partially implemented.)* The `/usr` tree builder exists (`lib/usr-tree.nix`); the erofs, verity,
UKI and repart steps are planned. The `image/` directory holds tool-independent definitions.

This page documents what a release contains and how sysupdate finds it. Names carry the image id and
version; the version sorts with `strverscmp`.

| artifact         | file name                                                    | sysupdate transfer                         |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------ |
| `/usr` image     | `<id>_<version>.usr.raw`                                     | `Type=partition`, `MatchPartitionType=usr` |
| verity hash tree | `<id>_<version>.usr-verity.raw`                              | `MatchPartitionType=usr-verity`            |
| verity signature | `<id>_<version>.usr-verity-sig.raw`                          | `MatchPartitionType=usr-verity-sig`        |
| UKI              | `<id>_<version>.efi` → installed as `<id>_<version>+3-0.efi` | `Type=regular-file`, path `/EFI/Linux`     |
| manifest         | `SHA256SUMS`                                                 | *(planned)* sysupdate `Verify=no` in v1    |

All transfers use `InstancesMax=2`.

## Image definitions (`image/`)

| file             | content                                                               |
| ---------------- | --------------------------------------------------------------------- |
| `default.nix`    | image identity, imports the other files                               |
| `erofs.nix`      | erofs compression, timestamp-from-version rule                        |
| `os-release.nix` | os-release template (`ID`, `VERSION_ID`, `IMAGE_ID`, `IMAGE_VERSION`) |
| `repart.nix`     | systemd-repart partition definitions (ESP, usr-a/b, verity, root)     |
| `sysupdate.nix`  | systemd-sysupdate transfer definitions (usr, verity, sig, UKI)        |
| `uki.nix`        | UKI cmdline template, PCR phases, Secure Boot signing paths           |

The definitions are data, not derivations. The builder *(partially implemented)* renders them to INI
files and calls the tools.

## `/usr` tree (`lib/usr-tree.nix`)

`usrTree { composerOutput; platform; version; }` produces a derivation whose output **is** the
complete `/usr` directory:

| path                           | content                                                                  |
| ------------------------------ | ------------------------------------------------------------------------ |
| `nix/store/<hash>-*`           | runtime closure of the packages (copied from the store)                  |
| `bin/`, `lib/`, `share/`       | relative symlinks into `nix/store/` (from `links` + expanded `farmDirs`) |
| `sbin`                         | symlink to `bin`                                                         |
| `lib/systemd/system/*.service` | unit files (from `composerOutput.units`)                                 |
| `lib/sysusers.d/golconda.conf` | sysusers lines                                                           |
| `lib/tmpfiles.d/golconda.conf` | tmpfiles lines                                                           |
| `lib/os-release`               | rendered from `image/os-release.nix` with the version                    |
| other `lib/`, `share/`         | files from `composerOutput.files` (paths under `/usr/`)                  |

### Verification (build-time)

1. **No absolute symlink targets.** Every symlink must use a relative path.
1. **dlopen sonames resolve.** Each soname declared in `dlopen` must have a working symlink in
   `lib/`.
1. **No setuid/setgid bits.** The tree must contain no executables with special permission bits.
1. **Allowed directories only.** Top-level directories are limited to `bin`, `lib`, `share`, `nix`,
   `libexec`, plus the `sbin` symlink.

### Reproducibility

A Nix store path carries no mtimes (Nix sets them to 1), so the tree itself has none. The image step
applies the timestamp derived from the version (`YYYYMMDD.N` → epoch seconds) with `mkfs.erofs -T`,
which is what makes `ConditionNeedsUpdate=` fire exactly once per version.

## Build requirements

- **Verity signature**: The `.usr-verity-sig.raw` file must be padded to a 512-byte boundary for
  `systemd-repart` to accept it as `CopyBlocks` source.

- **Root hash in cmdline**: The UKI cmdline must include `usrhash=<roothash>` where `<roothash>` is
  the hex-encoded dm-verity root hash. `systemd-gpt-auto-generator` uses this to find the correct
  `/usr` partition.

- **Running repart without sandbox**: Outside the Nix build sandbox, use:

  ```bash
  unshare --map-root-user fakeroot systemd-repart --architecture=x86-64 ...
  ```

- **UKI boot counting**: The installed UKI has `+3-0` suffix (3 tries left, 0 done).
  `systemd-bless-boot` removes the suffix after `boot-complete.target` is reached.
