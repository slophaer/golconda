# From server.toml to a booted machine

One configuration, followed from the document to an ssh login and an update. Every step names a
command. Output that appears below came from a real run, and the text says which run. Where no run
exists, the page says "not run".

Three kinds of run feed this page:

- **eval**: `nix-instantiate --eval` on the expression shown, 2026-11-01. `iets eval` takes the same
  expression. Evaluating `composed.links` needs iets (it uses dynamic derivations), so no link is
  quoted here.
- **boot**: `scripts/boot-test` on the host that builds the images, 2026-11-01, harness at commit
  `dbafac0`, image `image-smoke-test` (the example plus a test login key and an update source).
- **boot, TPM**: the same harness with `--secure-boot --ssh-test --tpm`, 2026-10-31. The sealing
  checks in the script have not changed since.

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
`/factory` and `/vars` are not named because they are always there. There is no `updateSource`, so
this image carries no update definitions (step 8 turns it on). The schema says what each table may
hold:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
```

## 2. Evaluation

`examples/golconda.nix` (the template to copy into your own repository) calls
`mkSystem { config = ./server.toml; }`. iets evaluates it:

```sh
iets eval --json -E '(import ./examples/golconda.nix).config'
```

This prints the normalized options after type-checking. A wrong value stops here with the module's
message (`'2026.10.0' is not a version: YYYYMMDD.N, such as 20261031.1`). An unknown table name
lists the valid paths: `/base`, `/factory`, `/network`, `/services/sshd`, `/system`.

## 3. The composer

`mkSystem` binds the platform's package set to `/pkgs.target`, calls `/services/sshd` for its
fragment, adds `/vars` and `/factory`, and hands the list to `/system`, which merges `/base`,
`/network` and `/security` first. The result is one attribute set:

```sh
iets eval --json -E 'builtins.attrNames (import ./examples/golconda.nix).composed'
```

```json
["files","links","name","origins","packageOrigins","packages","sysusers","tmpfiles","units","updateSource","version"]
```

*(eval.)* For this document:

- `units`: `golconda-etc-links.service`, `golconda-health-network.service`,
  `golconda-health-sshd.service`, `golconda-loader-update.service`,
  `golconda-var-sshd-hostkey.service`, `sshd.service`.

- `files` (36), by origin:

  - `/base` (22): `/usr/lib/repart.d/30-root.conf`, `/usr/lib/locale.conf`, the timesyncd and
    journald files, `dbus.socket` and `/usr/share/dbus-1/system.conf`, `golconda-loader-update` and
    `loader.conf`, `/usr/libexec/golconda-etc-links`, and thirteen unit drop-ins named
    `/usr/lib/systemd/system/<unit>.d/golconda.conf` (for example `systemd-firstboot.service`,
    `ldconfig.service`, `modprobe@.service`);
  - `/services/sshd` (4): `/usr/lib/sshd/sshd_config`, `/usr/lib/sshd/authorized_keys/root`, and the
    var's script and manifest `/usr/lib/golconda/vars.d/sshd-hostkey.{sh,json}`;
  - `/network` (1): `99-default-dhcp.network`; `/security` (1):
    `/usr/lib/sysctl.d/50-golconda.conf`;
  - the var runner `/usr/lib/golconda/golconda-var-run` (1);
  - `/factory` (7): `pam.d/other`, `pam.d/sshd`, `pam.d/systemd-user`, `shells` and three `.keep`
    files, under `/usr/share/factory/etc`.

  There is no `ca.pub`, no `principals/` and no `/usr/lib/sysupdate.d/`: the example sets none of
  them.

- `sysusers`: `u messagebus - "D-Bus message bus user" -` and
  `u sshd - "SSH privilege separation" /var/empty`.

- `tmpfiles`: `L /bin`, `L /sbin` and `L /lib` into `usr/`; `L /etc/ssl/cert.pem` and
  `L /etc/ssl/certs/ca-certificates.crt`; `d /var/empty`; one
  `L /etc/<path> - - - - /usr/share/factory/etc/<path>` per factory file; `L /etc/localtime`
  (`/usr/share/zoneinfo/UTC`); `L /etc/os-release`; `d /etc/ssh`.

- `packageOrigins`: `openssh` from `/services/sshd`; `cacert`, `dash`, `dbus-broker`, `e2fsprogs`,
  `linux-kernel`, `systemd`, `tpm2-tss`, `tzdata` and `uutils-coreutils` from `/base`.

- `links`: not quoted (see above). It holds every `bin` name of the packages as `/usr/bin/<name>`,
  systemd's directories as `farm` links, one link per dlopen soname, and the `.wants` links.

The service unit, as
`iets eval --raw -E '(import ./examples/golconda.nix).composed.units."sshd.service"'` prints it
*(eval)*:

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
nix-build -E '(import ./examples/golconda.nix).usrTree'     # or: iets build … (a patched Nix daemon builds it)
```

`lib/usr-tree.nix` copies the closure of the packages into `nix/store/`, makes the symlinks
(relative, `farm` links expanded file by file), writes the units, `sysusers.d/golconda.conf`,
`tmpfiles.d/golconda.conf`, `os-release`, every file of `files`, and the artifacts
`lib/golconda/{config,schema,sbom,packages}.json`. Then it checks the tree: no absolute symlink,
every dlopen link resolves, no setuid bit, only the allowed top-level directories. The output is
named `golconda-usr-20261031.1` *(eval of `usrTree.name`)* and is a directory that is `/usr`
([Image artifacts](image.md#usr-tree-libusr-treenix)).

## 5. The image

```sh
nix-build -A packages.x86_64-linux.image-smoke
```

builds the chain over `examples/server.toml`, with throwaway keys. From the `/usr` tree,
`lib/image/` makes, one derivation each:

- the erofs image with every mtime set to the epoch of `20261031.1` (`mkfs.erofs -T`);
- the verity hash tree, the root hash and the signed `usr-verity-sig`;
- the initrd (a second, smaller `/usr` tree: systemd, udev with the device-mapper rules,
  veritysetup, repart);
- the UKI: kernel, initrd and the cmdline of
  [The kernel command line](image.md#the-kernel-command-line), signed for Secure Boot, with a signed
  PCR 11 policy;
- the signed systemd-boot loader;
- the GPT disk with the ESP, the A slot filled, the B slot empty and no `root` partition (the disk
  has no room for one; the harness gives it room, see step 6).

The release names are `server_20261031.1.usr.<uuid>.raw`, `server_20261031.1.usr-verity.<uuid>.raw`,
`server_20261031.1.usr-verity-sig.raw` and `server_20261031.1.efi`, plus `SHA256SUMS`
([Image artifacts](image.md#a-release)). The output also holds `keys/`, the throwaway keys.

## 6. First boot

Do not start the disk with a bare `qemu-system-x86_64 -bios OVMF.fd`. The image enforces IPE: the
kernel trusts the verity signature only from the platform keyring, which the firmware fills from the
Secure Boot `db`. Plain `OVMF.fd` has no Secure Boot, so the boot stops at switch-root with
`Failed to execute /sbin/init` ([Image artifacts](image.md#boot-test-scriptsboot-test)). The harness
does what is needed: it enrols the throwaway db key into the OVMFFull variable store, starts QEMU
with SMM and a 40 GiB overlay (room for `root`), and passes the host name `boot-test` as an SMBIOS
credential.

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
PASS: no-firstboot-prompt (firstboot ran without prompting)
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
   `systemd-firstboot --mute-console=yes`. It never prompts, and still applies `firstboot.*`
   credentials. Marker: `no-firstboot-prompt`.
1. systemd-sysusers writes `passwd`, `group` and `shadow` from `sysusers.d/golconda.conf`
   (`messagebus`, `sshd`).
1. systemd-tmpfiles runs `tmpfiles.d/golconda.conf`: `/etc/pam.d/sshd`, `/etc/shells` and the other
   factory files become symlinks into `/usr/share/factory/etc`; `/etc/localtime`, `/etc/os-release`,
   `/etc/ssh` and `/var/empty` exist.
1. `golconda-var-sshd-hostkey.service` runs `golconda-var-run sshd-hostkey "key" "key.pub"`:
   `ssh-keygen -q -t ed25519 -N '' -f key` in a runtime directory, then
   `systemd-creds encrypt --with-key=auto --tpm2-public-key-pcrs=11 --name=sshd-hostkey.key` of the
   key into `/etc/credstore.encrypted/sshd-hostkey.key`. The public half goes to
   `/var/lib/golconda/vars/sshd-hostkey/pub/key.pub`, and a `done` file ends the unit's future runs.
   Marker: `var-sshd-hostkey`. `--with-key=auto` seals to the host key plus the TPM2 when a TPM2
   exists, and to the host key alone when it does not; the plain run above has no TPM.
1. `sshd.service` starts with the host key unsealed into its credentials directory. networkd brings
   up DHCP on the wired link. `golconda-health-network.service` and `golconda-health-sshd.service`
   must pass before `boot-complete.target`, which blesses the entry (`+3-0` becomes
   `server_20261031.1.efi`). Markers: `sshd-active`, `boot-complete`.

`--ssh-test` adds the checks that need a login (step 7). With `--ssh-test --tpm` the harness starts
swtpm, checks the sealing of the host key and reboots the guest. Output *(boot, TPM)*:

```text
sshd-hostkey.key sealed with: host key + TPM2 + signed PCR policy (header id afbfeaac...)
PASS: hostkey-sealed-with-tpm2
...
PASS: ssh-after-reboot (boot id 5d268c9d-e07d-412f-accd-4ff41faacf08 -> 991be2e5-bb6f-4c85-9859-fda7f7fc8518)
PASS: hostkey-unchanged (unsealed from the TPM, not regenerated)
PASS: sshd-active-after-reboot
```

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

The harness forwards host port 10022 (`BOOT_TEST_SSH_PORT`) to the guest's port 22 and logs in as
root with `ssh -i tests/fixtures/snakeoil-ssh -p 10022 root@localhost`. In the run *(boot)*,
`--ssh-test` printed `PASS: ssh-login`, `PASS: no-failed-units` and
`PASS: varlinkctl-list-interfaces`, and the 27 ssh checks of that run all passed.

Certificate login: uncomment the three lines at the end of `examples/server.toml`. The evaluation
*(eval, with an `admin@example.com` principal)* adds `/usr/lib/sshd/ca.pub` and
`/usr/lib/sshd/principals/root`, and two lines to `sshd_config`:

```text
TrustedUserCAKeys /usr/lib/sshd/ca.pub
AuthorizedPrincipalsFile /usr/lib/sshd/principals/%u
```

A certificate login is **not run**: `scripts/boot-test` logs in with a plain key, so no test signs a
certificate or checks the principal. The host key's public half is in
`/var/lib/golconda/vars/sshd-hostkey/pub/key.pub` for enrolment. The options `hostCertificate` and
`revokedKeys` add an admin-supplied host certificate and revocation list as further vars; they are
not run either.

## 8. The next version

Set `updateSource = "https://updates.example.com/server/"` in `"/system"` and the composer adds
`/usr/lib/sysupdate.d/{10-usr,20-usr-verity,30-usr-verity-sig,40-uki}.transfer` and the update timer
*(eval)*. To release a new version, change `version`, rebuild and publish the `release/` directory
([Releases](../design/releases.md)); `systemd-sysupdate-update.service` on the machine writes the B
slots and the new UKI to the ESP, and the next boot runs them. Three failed boots make systemd-boot
choose the other slot ([Updates](../design/updates.md)).

The harness runs this whole update. `scripts/boot-test … --next DIR` copies the next release into
the guest, installs it, reboots, and checks the result. Output *(boot)*:

```text
PASS: release-index (4 lines: usr, verity, signature, UKI; digests match)
Successfully installed '/var/tmp/next/boot-test_20261031.2.efi' (regular-file) as '/boot/EFI/Linux/boot-test_20261031.2+3-0.efi' (regular-file).
* Successfully installed update '20261031.2'.
PASS: sysupdate-installed (20261031.2)
PASS: boots-next (20261031.1 -> 20261031.2)
PASS: etc-links-stable (372 links, 0 naming a store path, 0 dangling)
PASS: no-failed-units-after-update
```

The limits of this test are on [Image artifacts: the update test](image.md#the-update-test): the
transfer is a local copy, not HTTP, and no test yet makes the health check fail to prove the
fallback after three boots.
