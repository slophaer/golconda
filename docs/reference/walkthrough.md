# From server.toml to a booted machine

One configuration, followed from the document to an ssh login. Steps 1 to 5 name the command or the
output that exists; steps 6 to 8 are described, not yet proven on a machine, and say so.

## 1. The document

`examples/server.toml`, with certificate login turned on:

```toml
["/system"]
name = "server"
version = "20261031.1"
updateSource = "https://updates.example.com/server/"

["/services/sshd"]
trustedUserCAKeys = ["ssh-ed25519 AAAA... user-ca"]
["/services/sshd".principals]
root = ["alice@example.com"]
```

Two module tables: the image's identity and update source, and one service (whose `principals` is a
sub-table). `/base`, `/network`, `/security`, `/factory` and `/vars` are not named because they are
always there. The schema says what each table may hold:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
```

## 2. Evaluation

`golconda.nix` (the copy of the template next to the document; `examples/golconda.nix` inside the
repository) calls `mkSystem { config = ./server.toml; }`. iets evaluates it:

```sh
iets eval --json -E '(import ./examples/golconda.nix).config'
```

prints the normalized options after type-checking. A wrong value stops here with the module's
message (`'2026.10.0' is not a version: YYYYMMDD.N, such as 20261031.1`; an unknown table name lists
the valid paths).

## 3. The composer

`mkSystem` binds the platform's package set to `/pkgs.target`, calls `/services/sshd` for its
fragment, adds `/vars` and `/factory`, and hands the list to `/system`, which merges `/base`,
`/network` and `/security` first. The result, `(import ./examples/golconda.nix).composed`, is one
attribute set:

For this document (print any field with `iets eval`, for example
`--json -E '(import ./examples/golconda.nix).composed.links'`; the numbers depend on the document,
so none is quoted here):

- `units`: `sshd.service`, `golconda-var-sshd-hostkey.service`.
- `files`: `/usr/lib/sshd/*` (the sshd configuration, the CA key, the principals);
  `/usr/lib/sysupdate.d/*.transfer` when `updateSource` is set; the network file; the timesyncd,
  journald and sysctl files; `/usr/lib/locale.conf`; `/usr/lib/repart.d/30-root.conf`;
  `/usr/lib/systemd/system.conf.d/golconda-dlopen.conf`; `dbus.socket`; the var script, its manifest
  and the runner; the factory files under `/usr/share/factory/etc`.
- `sysusers`: `u messagebus …`, `u sshd - "SSH privilege separation" /var/empty`.
- `tmpfiles`: `L /bin`, `L /sbin`, `L /lib`; one
  `L /etc/<path> - - - - /usr/share/factory/etc/<path>` line per factory file; `L /etc/localtime`,
  `L /etc/os-release`; `d /etc/ssh`, `d /var/empty`.
- `packages`: systemd, dbus-broker, dash, uutils-coreutils, tpm2-tss, e2fsprogs, linux-kernel (from
  `/base`) and openssh (from `/services/sshd`).
- `packageOrigins`: `{ openssh = [ "/services/sshd" ]; systemd = [ "/base" ]; … }`.
- `links`: every `bin` name of the packages as `/usr/bin/<name>`, `/usr/bin/sh` → dash, the
  executables `/base` lists by hand, systemd's directories as `farm` links, one link per dlopen
  soname, and the `.wants` links.

The unit, as `iets eval --raw -E '(import ./examples/golconda.nix).composed.units."sshd.service"'`
prints it:

```ini
[Unit]
Description=sshd
After=network.target
After=golconda-var-sshd-hostkey.service
Wants=golconda-var-sshd-hostkey.service

[Service]
ExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/sshd-hostkey.key
LoadCredentialEncrypted=sshd-hostkey.key
KillMode=process
User=root

[Install]
WantedBy=multi-user.target
```

Nothing in it is per-machine: the host key is `%d/sshd-hostkey.key`, a credential the machine makes.
The CA key and the principals file are lines in `/usr/lib/sshd/sshd_config`
(`TrustedUserCAKeys /usr/lib/sshd/ca.pub`, `AuthorizedPrincipalsFile /usr/lib/sshd/principals/%u`).

## 4. The `/usr` tree

```sh
nix-build -E '(import ./examples/golconda.nix).usrTree'     # or: iets build … (a patched Nix daemon builds it)
```

`lib/usr-tree.nix` copies the closure of the packages into `nix/store/`, makes the symlinks
(relative, `farm` links expanded file by file), writes the units, `sysusers.d/golconda.conf`,
`tmpfiles.d/golconda.conf`, `os-release`, every file of `files`, and the artifacts
`lib/golconda/{config,schema,sbom,packages}.json`; then it checks the tree (no absolute symlink,
every dlopen link resolves, no setuid bit, only the allowed top-level directories). The output is
`golconda-usr-20261031.1`, a directory that is `/usr`
([Image artifacts](image.md#usr-tree-libusr-treenix)).

## 5. The image

From the `/usr` tree, `lib/image/` makes, one derivation each: the erofs image with every mtime set
to `20261031.1`'s epoch (`mkfs.erofs -T`); the verity hash tree, root hash and the signed
`usr-verity-sig`; the initrd (a second, smaller `/usr` tree: systemd, udev with the device-mapper
rules, veritysetup, repart); the UKI (kernel + initrd + the cmdline of
[Boot](../design/boot.md#kernel-command-line), Secure Boot and PCR 11 signed); and the GPT disk with
the ESP, the A slot filled, the B slot empty and no root partition (the disk has no room for one;
see step 6). The artifacts are named
`server_20261031.1.{usr.raw,usr-verity.raw,usr-verity-sig.raw,efi}` ([Image artifacts](image.md)).

## 6. First boot *(described, not yet proven on a machine)*

What is proven: the disk (`disk.raw` in the `image-smoke-disk` output) boots in QEMU through
systemd-boot, the UKI, the initrd (verity attached, root made) and switch-root to `basic.target`,
with networkd, resolved and timesyncd running, and with the smoke's stand-ins
([Boot](../design/boot.md#kernel-command-line)). The disk is fully allotted (ESP, A, B), so give
repart room for `root` with an overlay:

```sh
qemu-img create -f qcow2 -b disk.raw -F raw root.qcow2 40G
qemu-system-x86_64 -m 2G -bios OVMF.fd -drive file=root.qcow2,format=qcow2 \
  -smbios type=11,value=io.systemd.credential:system.hostname=web1 -serial stdio
```

What is not proven, and the list below describes: systemd-firstboot (the boot stops at its
interactive root-password prompt today), the var sealing, `multi-user.target`, sshd, sysupdate.

1. systemd-boot runs `server_20261031.1+3-0.efi`; the stub measures it; the initrd finds `usr-a` by
   `usrhash=`, sets up verity, and repart creates `root` from `30-root.conf` (ext4, the rest of the
   disk).
1. After switch-root, PID 1 writes `/etc/machine-id`; systemd-firstboot writes `/etc/hostname` from
   the credential.
1. systemd-sysusers writes `passwd`, `group` and `shadow` from `sysusers.d/golconda.conf`: root,
   `messagebus`, `sshd`.
1. systemd-tmpfiles runs `tmpfiles.d/golconda.conf`: `/etc/pam.d/sshd`, `/etc/shells`, … become
   symlinks into `/usr/share/factory/etc`; `/etc/localtime`, `/etc/os-release`, `/etc/ssh`,
   `/var/empty` exist.
1. `golconda-var-sshd-hostkey.service` runs `golconda-var-run sshd-hostkey "key" "key.pub"`:
   `ssh-keygen -t ed25519` in a runtime directory, `systemd-creds encrypt --with-key=tpm2` of the
   key into `/etc/credstore.encrypted/sshd-hostkey.key`, the public half to
   `/var/lib/golconda/vars/sshd-hostkey/pub/key.pub`, and `done`.
1. `sshd.service` starts with `hostkey` unsealed into its credentials directory; networkd has
   brought up DHCP on the wired link; `boot-complete.target` blesses the entry
   (`server_20261031.1.efi`).

## 7. Login *(described, not yet proven on a machine)*

The operator's certificate comes from the CA whose public key is `ca.pub`, with the principal
`alice@example.com`; `principals/root` allows that principal as root:

```sh
ssh -i ~/.ssh/id_ed25519 -o CertificateFile=~/.ssh/id_ed25519-cert.pub root@web1
```

sshd checks the certificate against `TrustedUserCAKeys`, the principal against
`AuthorizedPrincipalsFile`, and logs `Accepted publickey for root … ID alice@example.com serial …`:
the audit trail. PAM (`account`, `session`) runs; no password is ever asked. The host's own key is
the one generated in step 6; its fingerprint is in `/var/lib/golconda/vars/sshd-hostkey/pub/key.pub`
for enrolment, and a host certificate and a revocation list can follow as admin vars
(`hostCertificate = true`, `revokedKeys = true`).

## 8. The next version *(described, not yet proven on a machine)*

Change the document, set `version = "20261101.1"`, rebuild: the four artifacts land in
`https://updates.example.com/server/`, `systemd-sysupdate update` on the machine writes them to the
B slot and the ESP, and the next boot runs them; three failed boots fall back to A
([Updates](../design/updates.md)).
