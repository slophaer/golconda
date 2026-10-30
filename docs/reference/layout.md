# Partitions and paths

The exact on-disk layout. Type GUIDs are the Discoverable Partitions Specification names as
`systemd-repart` spells them.

## Partitions

| label | type | filesystem | flags | size | |---|---|---|---|---| | `esp` | `esp` | vfat | — | 1
GiB | | `usr-a` | `usr` | erofs | read-only | image size | | `usr-a-verity` | `usr-verity` | — |
read-only | ~1 % of usr | | `usr-a-verity-sig` | `usr-verity-sig` | — | read-only | 16 KiB | |
`usr-b`, `usr-b-verity`, `usr-b-verity-sig` | as above | empty until the first update | | | | `root`
| `root` | ext4 on LUKS2 | growfs | rest of the disk, created on first boot |

## Paths

| path | kind | owner | |---|---|---| | `/usr/nix/store` | image | repkgs closure | | `/usr/bin`,
`/usr/lib`, `/usr/share` | image | symlink farm, composer files | | `/usr/lib/os-release` | image |
composer: `ID`, `VERSION_ID`, `IMAGE_ID`, `IMAGE_VERSION` | | `/usr/share/factory/etc` | image |
composer | | `/etc` | root partition | factory copy, admin | | `/var` | root partition | services |
| `/efi` | ESP | systemd-boot, UKIs, sysupdate |
