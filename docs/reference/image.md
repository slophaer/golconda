# Image artifacts

The `/usr` tree builder exists (`lib/usr-tree.nix`); the erofs, verity, initrd, UKI and disk steps
are *(being built)* in `lib/image/`. The `image/` directory holds the tool-independent definitions
they render.

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

The definitions are data. The composer renders `sysupdate.nix` today; the image builder renders the
rest.

## `/usr` tree (`lib/usr-tree.nix`)

`usrTree { composerOutput; platform; version; buildSystem ? platform.name; sbomDrv ? null; }`
produces a derivation whose output **is** the complete `/usr` directory; `mkSystem` calls it with
the artifacts added ([Configuration](config.md#the-entry-point)):

| path                                     | content                                                                       |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `nix/store/<hash>-*`                     | the runtime closure of `composerOutput.packages`                              |
| `bin/`, `lib/`, `share/`                 | relative symlinks into `nix/store/` (from `links`; kind `farm` expanded)      |
| `sbin`                                   | symlink to `bin`                                                              |
| `lib/systemd/system/<name>`              | unit files (from `composerOutput.units`)                                      |
| `lib/sysusers.d/golconda.conf`           | sysusers lines                                                                |
| `lib/tmpfiles.d/golconda.conf`           | tmpfiles lines                                                                |
| `lib/os-release`                         | rendered from `image/os-release.nix` with the version and the architecture    |
| `lib/golconda/packages.json`             | each package with name, version, store path and the fragments that brought it |
| `lib/golconda/{config,schema,sbom}.json` | from `mkSystem`: the normalized options, the schema, the SBOM                 |
| other `lib/`, `share/`                   | files from `composerOutput.files` (paths under `/usr/`, with their mode)      |

Build-time verification: no absolute symlink target; every `dlopen` link resolves and every `farm`
link names a directory; no setuid or setgid bit; no top-level directory other than `bin`, `lib`,
`share`, `nix`, `libexec` and the `sbin` link.

A Nix store path carries no mtimes (Nix sets them to 1), so the tree itself has none. The erofs step
applies the timestamp derived from the version (`YYYYMMDD.N` → epoch seconds, `versionToEpoch`) with
`mkfs.erofs -T`.

## Builder constraints *(being built)*

- The `.usr-verity-sig.raw` file is padded to a 512-byte boundary so that `systemd-repart` accepts
  it as a `CopyBlocks=` source.
- The UKI cmdline carries `usrhash=<root hash>`, which `systemd-gpt-auto-generator` uses to find the
  `/usr` partition; the partition UUIDs of `usr-a` and `usr-a-verity` are the two halves of that
  hash.
- Outside the Nix sandbox, repart runs as
  `unshare --map-root-user fakeroot systemd-repart --architecture=<names.systemd> …`.
