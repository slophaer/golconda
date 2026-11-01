# Partitions and paths

The exact on-disk layout. Type GUIDs are the Discoverable Partitions Specification names as
`systemd-repart` spells them; the definitions are `image/repart.nix`.

## Partitions

| label                                       | type             | filesystem | flags                 | size                                                                              |
| ------------------------------------------- | ---------------- | ---------- | --------------------- | --------------------------------------------------------------------------------- |
| `esp`                                       | `esp`            | vfat       | —                     | 512 MiB                                                                           |
| `usr-a`                                     | `usr`            | erofs      | read-only             | 10 GiB; the erofs image inside is much smaller                                    |
| `usr-a-verity`                              | `usr-verity`     | —          | read-only             | 128 MiB                                                                           |
| `usr-a-verity-sig`                          | `usr-verity-sig` | —          | read-only             | 16 KiB                                                                            |
| `usr-b`, `usr-b-verity`, `usr-b-verity-sig` | as above         |            |                       | the same sizes as A, empty until the first update                                 |
| `root`                                      | `root`           | ext4       | growfs, factory-reset | the rest of the disk, created on first boot (unencrypted in v1, LUKS2+TPM2 later) |

The slots are fixed at 10 GiB so an update of a grown image always fits; both slots must hold any
release. The image builder sets the verity partitions to one fixed size as well (128 MiB,
`image/repart.nix`). The partition UUIDs of `usr-a` and `usr-a-verity` are derived from the verity
root hash, which is how gpt-auto finds the pair the UKI's `usrhash=` names.

## Paths

| path                                            | where | written by                                                                                                                                   |
| ----------------------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/usr/nix/store`                                | image | `lib/usr-tree.nix`: the closure of the composer's `packages`                                                                                 |
| `/usr/bin`, `/usr/lib`, `/usr/share`            | image | `lib/usr-tree.nix` from the composer's `links` (symlinks) and `files`                                                                        |
| `/usr/lib/systemd/system/<name>`                | image | the composer's `units`; `.wants/` links from `links`                                                                                         |
| `/usr/lib/systemd/user/<name>`                  | image | the composer's `files` (user-scope services)                                                                                                 |
| `/usr/lib/sysusers.d/golconda.conf`             | image | the composer's `sysusers` lines, one file                                                                                                    |
| `/usr/lib/tmpfiles.d/golconda.conf`             | image | the composer's `tmpfiles` lines, one file                                                                                                    |
| `/usr/lib/systemd/network/*.network`            | image | `/network`                                                                                                                                   |
| `/usr/lib/systemd/{timesyncd,journald}.conf.d/` | image | `/base`                                                                                                                                      |
| `/usr/lib/locale.conf`                          | image | `/base` (`LANG=C.UTF-8`)                                                                                                                     |
| `/usr/lib/sysupdate.d/*.transfer`               | image | `/system` from `updateSource` and `image/sysupdate.nix`                                                                                      |
| `/usr/lib/repart.d/30-root.conf`                | image | `/base`, rendered from `image/repart.nix`                                                                                                    |
| `/usr/lib/os-release`                           | image | `lib/usr-tree.nix` from `image/os-release.nix`; `ID`/`IMAGE_ID` are `/system.name`                                                           |
| `/usr/lib/golconda/packages.json`               | image | `lib/usr-tree.nix` from the composer's `packageOrigins`                                                                                      |
| `/usr/lib/golconda/vars.d/`, `golconda-var-run` | image | `/vars` and the var renderer                                                                                                                 |
| `/usr/lib/<service>/`                           | image | the service renderer: the app's files                                                                                                        |
| `/usr/share/factory/etc`                        | image | `/factory`                                                                                                                                   |
| `/etc`                                          | root  | tmpfiles `L` links into the factory; PID 1 (`machine-id`), sysusers (`passwd`, `group`, `shadow`); the administrator (`hostname`, if wanted) |
| `/etc/credstore.encrypted/`                     | root  | the var runner and the deploy tool: sealed credentials                                                                                       |
| `/var/lib/golconda/vars/<name>/`                | root  | the var runner: public halves and the `done` marker                                                                                          |
| `/var`                                          | root  | services (`StateDirectory=`), tmpfiles                                                                                                       |
| `/boot`                                         | ESP   | systemd-boot, the UKIs, sysupdate                                                                                                            |

Nothing writes `/etc/hostname`. PID 1 reads the `system.hostname` credential at every boot
([Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials)); `systemd-firstboot` reads
`firstboot.hostname`, a different credential.

The ESP is at `/boot`, not `/efi`: systemd-gpt-auto-generator(8) mounts the ESP at `/boot/` when
that directory is not used for XBOOTLDR, and the image has no XBOOTLDR partition.
`scripts/boot-test` reads `/boot/EFI/systemd`.
