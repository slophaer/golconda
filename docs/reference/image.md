# Image artifacts

*(Planned.)* The image builder is not implemented. The `image/` directory holds tool-independent
definitions that the builder will consume.

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

The definitions are data, not derivations. The builder (not yet implemented) renders them to INI
files and calls the tools.

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
