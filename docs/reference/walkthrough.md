# From server.toml to a booted machine

One configuration, followed from the document to an ssh login and an update. Every step names a
command. Output marked *(eval)* is what the expression shown prints. Output marked *(boot)* is what
`scripts/boot-test` prints for `image-smoke-test` (the example plus a test login key and an update
source).

## 1. The document

`examples/server.toml`, as it is in the repository:

```toml
["/system"]
name = "server"
version = "20261031.1"

["/services/sshd"]
port = 22
authorizedKeys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample admin@example.com",
]

# Certificate-based login: uncomment to enable.
# trustedUserCAKeys = ["ssh-ed25519 AAAA... user-ca-key"]
# ["/services/sshd".principals]
# root = ["admin@example.com"]
```

Two module tables: the image's identity and the one service. `/base`, `/network`, `/security`,
`/trust`, `/factory` and `/vars` are not named because they are always there. There is no
`updateSource`, so this image carries no update definitions (step 8 turns it on). The schema says
what each table may hold:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
```

## 2. Evaluation

`examples/golconda.nix` (the template to copy into your own repository) calls
`mkSystem { config = ./server.toml; }` on the Golconda tree it gets: in your repository the pinned
one, here this repository. iets evaluates it:

```sh
iets eval --json -E '(import ./examples/golconda.nix { golconda = import ./default.nix; }).config'
```

This prints the normalized options after type-checking. A wrong value stops here with the module's
message (`'2026.10.0' is not a version: YYYYMMDD.N, such as 20261031.1`). An unknown table name
lists the valid paths.

## 3. The composer

`mkSystem` binds the platform's package set to `/pkgs.target`, selects the components
(`lib/components.nix`: the built-ins `/base`, `/network`, `/security`, `/trust`, `/factory` and
`/vars`, then `/services/sshd` because the document has its table), calls each for its fragment, and
hands the list to `/system`, which unions them. The result is one attribute set:

```sh
iets eval --json -E 'builtins.attrNames (import ./examples/golconda.nix { golconda = import ./default.nix; }).composed'
```

[Modules: The composer output](modules/README.md#the-composer-output) describes the fields. For this
document, `units` holds `sshd.service`, the var unit of its host key and the units of `/base`.

The service unit, as
`iets eval --raw -E '(import ./examples/golconda.nix { golconda = import ./default.nix; }).composed.units."sshd.service"'`
prints it *(eval)*:

```ini
[Unit]
Description=sshd
After=network.target
After=golconda-var-sshd-hostkey.service
After=systemd-pcrphase-sysinit.service
Wants=golconda-var-sshd-hostkey.service

[Service]
ExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/sshd-hostkey.key
LoadCredentialEncrypted=sshd-hostkey.key
KillMode=process
User=root

[Install]
WantedBy=multi-user.target
```

Nothing in it is per-machine. The host key is `%d/sshd-hostkey.key`, a credential the machine makes.
`After=systemd-pcrphase-sysinit.service` keeps sshd from loading the sealed key before the PCR 11
phase that the UKI's signature covers (`modules/services/sshd/default.nix`).

`/usr/lib/sshd/sshd_config` *(eval)* turns passwords off, allows root by key only, and reads
`AuthorizedKeysFile .ssh/authorized_keys /usr/lib/sshd/authorized_keys/%u`. The example's key is the
one line in `/usr/lib/sshd/authorized_keys/root`.

## 4. The `/usr` tree

```sh
nix-build -E '(import ./examples/golconda.nix { golconda = import ./default.nix; }).usrTree'     # or: iets build … (a patched Nix daemon builds it)
```

`lib/usr-tree.nix` copies the closure of the packages into `nix/store/`, makes the symlinks
(relative, `farm` links expanded file by file), writes the units, `sysusers.d/golconda.conf`,
`tmpfiles.d/golconda.conf`, `os-release`, every file of `files`, and the artifacts
`lib/golconda/{config,schema,sbom,packages}.json`. Then it checks the tree: no absolute symlink,
every dlopen link resolves, only the allowed top-level directories. The output is named
`golconda-usr-20261031.1` *(eval of `usrTree.name`)* and is a directory that is `/usr`
([Image artifacts](image.md#usr-tree-libusr-treenix)).

## 5. The image

```sh
nix-build -A packages.x86_64-linux.image-smoke
```

builds the chain over `examples/server.toml`, with throwaway keys. Nix builds the `/usr` tree, the
initrd and the manifest unsigned; then the signer (`lib/image/sign.nu`), run in a derivation with
the throwaway keys, makes:

- the signed systemd-boot loader, which it puts into a copy of the `/usr` tree;
- the erofs image with every mtime set to the epoch of `20261031.1` (`mkfs.erofs -T`);
- the verity hash tree, the root hash and the signed `usr-verity-sig`;
- the UKI: kernel, initrd and the cmdline of
  [The kernel command line](image.md#the-kernel-command-line), signed for Secure Boot, with a signed
  PCR 11 policy;
- the GPT disk with the ESP, the A slot filled, the B slot empty and no `root` partition (the disk
  has no room for one; the harness gives it room, see step 6).

The release names are `server_20261031.1.usr.<uuid>.raw`, `server_20261031.1.usr-verity.<uuid>.raw`,
`server_20261031.1.usr-verity-sig.raw` and `server_20261031.1.efi`, plus `SHA256SUMS`
([Image artifacts](image.md#a-release)). The initrd (a second, smaller `/usr` tree: systemd, udev
with the device-mapper rules, veritysetup, repart) is a Nix output. The output also holds `keys/`,
the public halves of the throwaway keys. A release signs the same way, outside Nix, with your keys
([Making a release](release.md)).

## 6. First boot

Do not start the disk with a bare `qemu-system-x86_64` and a plain OVMF. A plain OVMF has no Secure
Boot, so nothing checks the loader or the UKI; the kernel still checks `/usr` against the `db`
certificate built into it, and IPE enforces ([Boot test](boot-test.md)). The harness does what is
needed: it enrols the throwaway db key into the variable store of OVMF's Secure Boot build
(`qemu-system`'s `share/qemu`), starts QEMU with SMM and a 40 GiB overlay (room for `root`), and
passes the host name `boot-test` as an SMBIOS credential.

```sh
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --timeout 120
```

The harness reads the serial log, since this example has no usable login key. Its five markers
*(boot)*:

```text
=== Marker checks (serial log) ===
PASS: multi-user-reached
PASS: sshd-active
PASS: var-sshd-hostkey
PASS: boot-complete
PASS: no-firstboot-prompt
```

What happens, in order, and which marker or file shows it:

1. systemd-boot runs the UKI `server_20261031.1+3-0.efi`. The stub measures it into PCR 11. The
   initrd finds `usr-a` by `usrhash=`, attaches verity, and repart creates `root` from
   `/usr/lib/repart.d/30-root.conf` (ext4, the rest of the disk).
1. After switch-root, PID 1 writes `/etc/machine-id` and takes the host name from the
   `system.hostname` credential at every boot; nothing writes `/etc/hostname`
   ([Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials)). `--ssh-test` checks it:
   `PASS: hostname (system.hostname credential applied)`.
1. `systemd-firstboot.service` runs with the drop-in
   `/usr/lib/systemd/system/systemd-firstboot.service.d/golconda.conf`:
   `systemd-firstboot --mute-console=yes`. The drop-in runs it without the `--prompt-*` options of
   systemd's unit, so it never prompts, and it still applies `firstboot.*` credentials. Marker:
   `no-firstboot-prompt`.
1. systemd-sysusers writes `passwd`, `group` and `shadow` from `sysusers.d/golconda.conf`
   (`messagebus`, `sshd`).
1. systemd-tmpfiles runs `tmpfiles.d/golconda.conf`: `/etc/pam.d/sshd`, `/etc/shells` and the other
   factory files become symlinks into `/usr/share/factory/etc`; `/etc/localtime`, `/etc/os-release`,
   `/var/empty` exists.
1. `golconda-var-sshd-hostkey.service` runs `golconda-var-run sshd-hostkey "key" "key.pub"`:
   `ssh-keygen -q -t ed25519 -N '' -f key` in a runtime directory, then
   `systemd-creds encrypt --with-key=auto --tpm2-public-key-pcrs=11 --name=sshd-hostkey.key` of the
   key into `/etc/credstore.encrypted/sshd-hostkey.key`, and `--tpm2-pcrs=7` on a Secure Boot image
   (`/usr/lib/golconda/vars.d/tpm2-pcrs`). The public half goes to
   `/var/lib/golconda/vars/sshd-hostkey/pub/key.pub`, and a `done` file ends the unit's future runs.
   Marker: `var-sshd-hostkey`. `--with-key=auto` seals to the host key plus the TPM2 when a TPM2
   exists, and to the host key alone when it does not; the plain run above has no TPM.
1. `sshd.service` starts with the host key unsealed into its credentials directory. networkd brings
   up DHCP on the wired link. `golconda-health-network.service` and `golconda-health-sshd.service`
   must pass before `boot-complete.target`, which blesses the entry (`+3-0` becomes
   `server_20261031.1.efi`). Markers: `sshd-active`, `boot-complete`.

`--ssh-test` adds the checks that need a login (step 7). With `--ssh-test --tpm` the harness starts
swtpm, checks the sealing of the host key (`hostkey-sealed-with-tpm2`), reboots the guest, and
checks that the same host key unseals (`ssh-after-reboot`, `hostkey-unchanged`,
`no-failed-units-after-reboot`).

The ESP is at `/boot` in the guest, since the image has no XBOOTLDR partition
([Partitions and paths](layout.md#paths)).

## 7. Login

The example logs in by key: the line in `authorizedKeys` ends in
`/usr/lib/sshd/authorized_keys/root`. Its key is a placeholder, so `--ssh-test` needs the
`image-smoke-test` image, which adds the public half of the committed test key
`tests/fixtures/snakeoil-ssh`:

```sh
nix-build -A packages.x86_64-linux.image-smoke-test
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test
```

The harness forwards a host port (`BOOT_TEST_SSH_PORT`, or the first free one from 10022 up) to the
guest's port 22 and logs in as root with
`ssh -i tests/fixtures/snakeoil-ssh -p 10022 root@localhost`. `--ssh-test` checks, among others,
`ssh-login`, `no-failed-units` and `varlinkctl-list-interfaces`.

Certificate login: uncomment the three lines at the end of `examples/server.toml`. The evaluation
*(eval, with an `admin@example.com` principal)* adds `/usr/lib/sshd/ca.pub` and
`/usr/lib/sshd/principals/root`, and two lines to `sshd_config`:

```text
TrustedUserCAKeys /usr/lib/sshd/ca.pub
AuthorizedPrincipalsFile /usr/lib/sshd/principals/%u
```

The host key's public half is in `/var/lib/golconda/vars/sshd-hostkey/pub/key.pub` for the host CA.
The options `hostCertificate` and `revokedKeys` add an admin-supplied host certificate and
revocation list as further vars. The boot test runs all of this with its own test CA, not with this
document: `--ssh-test` logs in with a user certificate and refuses another principal (`cert-login`,
`cert-wrong-principal-refused`), and `--next` certifies the host and pushes the KRL with
`golconda vars certify`, then checks that the next release presents the host certificate and refuses
a revoked certificate (`host-cert-presented`, `cert-revoked-refused`, `krl-rotated`); `--certify`
does the push in the first boot of a release that has both options on (`certify-one-release`). See
[What is proven](../proven.md).

## 8. The next version

Set `updateSource = "https://updates.example.com/server/"` in `"/system"` and the composer adds
`/usr/lib/sysupdate.d/{10-usr,20-usr-verity,30-usr-verity-sig,40-uki}.transfer` and the update timer
*(eval)*. To release a new version, run `golconda release build` again: it picks the next version,
writes it into the document and commits it. Then publish the `release/` directory
([Releases](../design/releases.md)); `systemd-sysupdate-update.service` on the machine writes the B
slots and the new UKI to the ESP, and `systemd-sysupdate-reboot.timer` reboots into them at 04:10
(`/system.updateReboot`). Three failed boots make systemd-boot choose the other slot
([Updates](../design/updates.md)).

The harness runs this whole update. `scripts/boot-test … --next DIR` serves the next release over
HTTP at the image's `updateSource`, lets the guest install it, moves the reboot window to every 10
s, waits for the guest to reboot itself, and checks the result: `release-index`,
`sysupdate-installed`, `boots-next`, `units-composed-only-after-update` and
`no-failed-units-after-update`.

The limits of this test are on [Boot test: the update test](boot-test.md#the-update-test).
