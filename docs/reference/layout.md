# Partitions and paths

The exact on-disk layout. Type GUIDs are the Discoverable Partitions Specification names as
`systemd-repart` spells them; the definitions are `image/repart.nix`.

## Partitions

| definition                               | label                      | type             | filesystem | flags                 | size                                                                                |
| ---------------------------------------- | -------------------------- | ---------------- | ---------- | --------------------- | ----------------------------------------------------------------------------------- |
| `00-esp`                                 | `esp` (repart's default)   | `esp`            | vfat       | —                     | 512 MiB                                                                             |
| `10-usr-a`                               | `usr_<version>`            | `usr`            | erofs      | read-only             | 10 GiB; the erofs image inside is much smaller                                      |
| `11-usr-a-verity`                        | `usr-verity_<version>`     | `usr-verity`     | —          | read-only             | 128 MiB                                                                             |
| `12-usr-a-verity-sig`                    | `usr-verity-sig_<version>` | `usr-verity-sig` | —          | read-only             | 16 KiB                                                                              |
| `20-usr-b`                               | `_empty`                   | `usr`            | —          | read-only             | 10 GiB, empty until the first update                                                |
| `21-usr-b-verity`, `22-usr-b-verity-sig` | `_empty`                   | as in slot A     | —          | none                  | the same sizes as in slot A, empty until the first update                           |
| `30-root`                                | `root`                     | `root`           | ext4       | growfs, factory-reset | the rest of the disk, created on first boot (unencrypted for now, LUKS2+TPM2 later) |

The definitions are the entries of `image/repart.nix`. An update labels the slot it writes with the
release's version, and a free slot is `_empty` ([Image artifacts: A release](image.md#a-release)).
`21-usr-b-verity` and `22-usr-b-verity-sig` have no `ReadOnly=`.

The slots are fixed at 10 GiB so an update of a grown image always fits; both slots must hold any
release. The ESP holds two UKIs and 8 MiB for the loader and its files, so the signer refuses a UKI
larger than (512 MiB − 8 MiB) / 2 = 252 MiB. The image builder sets the verity partitions to one
fixed size as well (128 MiB, `image/repart.nix`). The partition UUIDs of `10-usr-a` and
`11-usr-a-verity` are derived from the verity root hash, which is how gpt-auto finds the pair the
UKI's `usrhash=` names.

## Paths

| path                                            | where | written by                                                                                                                                   |
| ----------------------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/usr/nix/store`                                | image | `lib/usr-tree.nix`: the closure of the composer's `packages`                                                                                 |
| `/usr/bin`, `/usr/lib`, `/usr/share`            | image | `lib/usr-tree.nix` from the composer's `links` (symlinks) and `files`                                                                        |
| `/usr/lib/systemd/system/<name>`                | image | the composer's `units`; `.wants/` links from `links`                                                                                         |
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
