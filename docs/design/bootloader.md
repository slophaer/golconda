# Boot loader

One systemd-boot on the ESP starts both `/usr` slots. It is signed with the Secure Boot `db` key, it
ships inside the signed `/usr` of each release, and a machine copies it to the ESP only after that
release has booted and passed its health gate. The loader has no A/B of its own, so this page also
covers what changes it, how the `db` key is rotated, and how a machine is recovered when the loader
or a key goes wrong. The boot chain itself is in [Boot](boot.md), the keys in [Trust](trust.md).

## The loader in the image

The signer (`lib/image/loader.nu`, [Trust: Signing outside Nix](trust.md#signing-outside-nix)) signs
systemd's `systemd-boot<arch>.efi` with `systemd-sbsign`, with the same `db` key and certificate as
the UKI and the verity root hash. The result is used twice:

- **in `/usr`**, at `/usr/lib/systemd/boot/efi/systemd-boot<arch>.efi.signed`, beside the unsigned
  file the systemd farm links. The signer puts the file into its copy of the `/usr` tree before it
  makes the erofs image; the tree Nix builds has nothing at that path. The name is the one bootctl
  prefers to the unsigned file.
- **on the ESP**, the same file, written by the signer's disk step (`lib/image/disk.nu`). The signer
  fails unless the tree's `/usr/lib/golconda/loader.conf` is the disk's `loader.conf`. A fresh disk
  is therefore already in the state the machine keeps.

The ESP has the layout `bootctl install` makes:

| path on the ESP                            | what                                                 |
| ------------------------------------------ | ---------------------------------------------------- |
| `EFI/BOOT/BOOTX64.EFI`                     | the signed loader on the removable-media path        |
| `EFI/systemd/systemd-bootx64.efi`          | the same file, the primary copy                      |
| `EFI/systemd/systemd-boot-fallbackx64.efi` | the loader before the last update (after one update) |
| `loader/loader.conf`                       | `timeout 0`, `editor no` (`image/loader.nix`)        |
| `EFI/Linux/<id>_<version>[+N-M].efi`       | one UKI per slot                                     |

Firmware starts `EFI/BOOT/BOOTX64.EFI`: Golconda writes no `Boot####` variable, and OVMF falls back
to the removable-media path. `aa64` and `riscv64` use their own names (`removableMediaName`).

`loader.conf` is at the root of the ESP because systemd-boot reads `\loader\loader.conf` and nothing
else (`src/boot/boot.c`, systemd 262.1). A file at `EFI/loader/loader.conf` is never read:
`bootctl status` says `config: /boot//loader/loader.conf: No such file or directory`, and the menu
runs with systemd-boot's defaults, the editor on. With the file in place `bootctl status` says
`config: /boot//loader/loader.conf`.

## The loader on a running machine

`golconda-loader-update.service` (`/base`) runs `/usr/lib/golconda/golconda-loader-update`. The
program compares the running `/usr`'s signed loader and `loader.conf` with the ESP's files by
SHA-256 and copies what differs. Each copy goes beside its destination, is flushed, and is renamed
over it. A replaced primary copy is first kept as `EFI/systemd/systemd-boot-fallback<arch>.efi`, the
name `bootctl update` uses too. `EFI/BOOT/BOOTX64.EFI`, the file firmware starts, is written last.

```mermaid
flowchart TD
  upd[sysupdate writes slot B and its UKI +3-0] --> boot[reboot: the old loader starts the new UKI]
  boot --> gate{health units pass?}
  gate -->|no| keep[bless-boot does not run; the loader update does not run; ESP unchanged]
  gate -->|yes| bless[systemd-bless-boot.service: entry good]
  bless --> lu[golconda-loader-update.service]
  lu --> same{ESP loader = /usr loader?}
  same -->|yes| done[up to date]
  same -->|no| copy[keep the old primary as fallback; copy primary, then BOOTX64.EFI; loader.conf]
```

The unit is wanted by `systemd-bless-boot.service` (a link in its `.wants/`), ordered `After=` it,
and `Requisite=` it. `systemd-bless-boot-generator` pulls bless-boot in only on a counted boot, and
bless-boot runs only when `boot-complete.target` is reached
([Boot: Boot health](boot.md#boot-health)). So:

- a release installs its loader once, on its first good boot;
- a release that fails its health gate never touches the loader;
- a boot of an older blessed entry (fallback, `bootctl set-oneshot`, `set-default`) installs
  nothing, and the ESP keeps the newer loader. systemd-boot starts any UKI that firmware accepts, so
  a newer loader starts the older release.

The copy is safe for Secure Boot without a check on the machine: firmware has just accepted the
running UKI under the current `db` and `dbx`, and the image builder signs that release's loader with
the same key. A loader written by this unit is one this firmware starts, as long as `db` and `dbx`
do not change before the next boot.

**Why not `systemd-boot-update.service`.** systemd's unit runs `bootctl --graceful update`. That is
wrong for Golconda in three ways:

- It compares version strings, so it skips a loader signed again with a new key: the version is the
  same and the bytes differ.
- It runs before `sysinit.target`, so a candidate would install its loader before its health gate.
- It does nothing unless `EFI/systemd/` exists, and the image does not create that directory.

A drop-in turns it off (`ConditionPathExists=!/usr/lib/golconda/golconda-loader-update`), so the ESP
has one writer.

## Key rotation

A `db` key rotation signs the loader, the UKI and the verity root hash with a new key; they are one
key ([Trust](trust.md#2-verity-key)). The PCR policy key is a separate key and does not change.

1. Make the new key pair and keep the old one.

1. Add the new certificate to `db`, beside the old one. A release signed with a key that is not in
   `db` is refused: firmware rejects its UKI, each attempt counts down, and after three the older
   slot boots.

1. Build the next release with the new key and install it as usual:

   ```sh
   golconda release build -f server.toml --keys /srv/golconda-keys-2 \
     --pcr-keys /srv/golconda-keys --index-keys /srv/golconda-keys
   ```

   `--keys` is the new `db` key, in a new directory; the old directory keeps the PCR key and the
   release key, which the running image trusts. The layout is in
   [Trust: Deployment keys](trust.md#deployment-keys). The old loader starts the new UKI, because
   both certificates are in `db`. At the first good boot `golconda-loader-update.service` installs
   the new loader: the systemd-boot version is the same and the bytes are not. The old loader stays
   as the fallback copy.

1. Install one more release signed with the new key, so the other slot holds no UKI signed with the
   old key. Clear any loader variable that names an old entry: `bootctl set-default ''`.

1. Replace `db` with the new certificate alone and add the old certificate to `dbx`.

How the variables are written depends on the machine. Firmware setup can enrol a certificate; with
the KEK's private key, an authenticated `db` append or `dbx` update can be written from the running
system, but the image has no tool for it. The boot test writes the variable store offline with
`virt-fw-vars`: `--add-db` for step 2, `--delete db --add-db <new> --add-dbx-cert <old>` for step 5.

Step 4 is there because of what happens without it. In a test run that left `bootctl set-default` on
the old entry, the boot after step 5 stopped: systemd-boot logged
`Error loading EFI binary \EFI\Linux\boot-test_20261031.1.efi: Access denied` and returned to
firmware, which found no other bootable option. A blessed entry has no counter, so systemd-boot does
not fall back from it by itself.

## Recovery

| situation                                          | path                                                                                                                                                                                                                                                               |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| a new release fails its health gate                | boot counting: three attempts, then the other slot ([Boot](boot.md#boot-health))                                                                                                                                                                                   |
| see what is on the ESP                             | `bootctl list` (both slots, counters, cmdlines), `bootctl status` (loader, `config:` line)                                                                                                                                                                         |
| boot the other slot once                           | `bootctl set-oneshot <id>_<version>.efi`, reboot; the next boot returns to the default                                                                                                                                                                             |
| boot the other slot until told otherwise           | `bootctl set-default <id>_<version>.efi`; undo with `bootctl set-default ''`                                                                                                                                                                                       |
| the loader on the ESP is damaged, the machine runs | `/usr/lib/golconda/golconda-loader-update` puts the running release's loader back                                                                                                                                                                                  |
| reach the firmware menu from a running machine     | `bootctl reboot-to-firmware true`, reboot. The systemd-boot entry "Reboot Into Firmware Interface" does the same at the console; the menu shows after `bootctl set-timeout-oneshot 10`                                                                             |
| the loader does not start any more                 | at the console, the firmware's boot menu: start `EFI/systemd/systemd-boot-fallbackx64.efi`, or a UKI under `EFI/Linux` as a file; then run `golconda-loader-update` or install a release                                                                           |
| the ESP is lost                                    | write the ESP partition of the release's `disk.raw` again, from another machine; it carries the loader, `loader.conf` and that release's UKI                                                                                                                       |
| the `db` key leaks                                 | rotate it, with the old certificate in `dbx` (above)                                                                                                                                                                                                               |
| the `db` private key is lost                       | running machines keep booting: the signatures they hold stay valid. No new release can be signed for them. Enrol a new key with the KEK (an authenticated write) or in firmware setup, then install a release signed with it (a rotation without step 3's overlap) |
| certificate login is broken                        | after enrolment no plain key logs in ([Trust: Enrolment](trust.md#enrolment)). At the console, boot the other slot if its release has `hostCertificate` off; else reflash the disk: the state partition and its sealed vars go, and the machine enrols again       |

The firmware path needs the console.

The boot test runs the one-shot and default entries, the loader reinstall and the firmware reboot
(`set-oneshot-other-slot`, `set-default-other-slot`, `loader-reinstall`, `reboot-to-firmware`), and
a rotation with the old certificate in `dbx` (`--rotate`). The rows for a loader that does not
start, a lost ESP, a lost `db` private key and a broken certificate login are *(being built)*: they
use what is on `main`, but no test runs them ([What is proven](../proven.md#not-proven)).

## What is not possible

- **No second loader.** Both slots share one ESP and one `BOOTX64.EFI`. A loader that firmware
  starts but that fails later stops every boot, and boot counting cannot help: counting is the
  loader's job. Installing only after a good boot and keeping the fallback copy make this rare, not
  impossible.
- **No unattended recovery from a refused default entry or a refused loader.** It takes the firmware
  menu at a console or a reflash. There is no local login and no rescue shell
  ([Boot: Serial console](boot.md#serial-console)).
- **The machine cannot change `db` or `dbx` by itself.** The image has no tool for authenticated
  variable writes, and systemd-boot enrols keys from `loader/keys/` only in setup mode.
- **No signature check before the copy.** The program trusts the build: the loader in `/usr` is
  signed with the key of the UKI that booted. A `/usr` built with two different keys would break
  that rule; the image chain gives both steps the same `sbKeys`.
- **The copy is not atomic on FAT.** A rename over an existing file on vfat is not a journalled
  operation. A power loss during the copy can damage one file; the removable-media copy is written
  last and the fallback copy stays.
- **`loader.conf` is not signed.** Someone who can write the disk offline can change it; it is menu
  policy, not protection ([Boot: Kernel command line](boot.md#kernel-command-line)).
- **A UKI signed with a key in `dbx` stays on the ESP** until an update replaces its slot. Choosing
  it fails as above.
- **PCR policy key rotation is not covered.** A credential sealed to the old PCR key does not unseal
  under a UKI signed with a new one ([Trust: Rollback weakness](trust.md#rollback-weakness)).
