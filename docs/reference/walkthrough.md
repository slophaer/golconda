# From server.toml to a booted machine

One configuration, followed from the document to an ssh login. Every step names the command or the
output that exists today; the image steps are *(being built)* and say so.

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

Three tables: the image's identity and update source, and one service. `/base`, `/network`,
`/factory` and `/vars` are not named because they are always there. The schema says what each table
may hold:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
```

## 2. Evaluation

`golconda.nix` (the copy of the template next to the document; `examples/golconda.nix` inside the
repository) calls `mkSystem { config = ./server.toml; }`. iets evaluates it:

```sh
iets eval --json -E '(import ./examples/golconda.nix).config'
```

prints the normalized options: the three tables after type-checking. A wrong value stops here with
the module's message (`'2026.10.0' is not a version: YYYYMMDD.N, such as 20261031.1`; an unknown
table name lists the valid paths).

## 3. The composer

`mkSystem` binds the platform's package set to `/pkgs.target`, calls `/services/sshd` for its
fragment, adds `/vars` and `/factory`, and hands the list to `/system`, which merges `/base` and
`/network` first. The result, `(import ./examples/golconda.nix).composed`, is one attribute set:

| field            | for this document                                                                                                                                                                                                                                                                                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `units`          | `sshd.service`, `golconda-var-sshd-hostkey.service`                                                                                                                                                                                                                                                                                                                                        |
| `files`          | `/usr/lib/sshd/{sshd_config,ca.pub,principals/root}`; `/usr/lib/sysupdate.d/{10-usr,20-usr-verity,30-usr-verity-sig,40-uki}.conf`; `/usr/lib/systemd/network/default-dhcp.network`; the timesyncd and journald drop-ins; `/usr/lib/locale.conf`; `dbus.socket`; `/usr/lib/golconda/vars.d/sshd-hostkey.{json,sh}` and the var runner; the six factory files under `/usr/share/factory/etc` |
| `sysusers`       | `u messagebus …`, `u sshd - "SSH privilege separation" /var/empty`                                                                                                                                                                                                                                                                                                                         |
| `tmpfiles`       | one `L /etc/<path> - - - - /usr/share/factory/etc/<path>` line per factory file, `L /etc/localtime`, `L /etc/os-release`, `d /etc/ssh`, `d /var/empty`                                                                                                                                                                                                                                     |
| `packages`       | systemd, dbus-broker, dash, uutils-coreutils, linux-kernel (from `/base`), openssh (from `/services/sshd`)                                                                                                                                                                                                                                                                                 |
| `packageOrigins` | `{ openssh = [ "/services/sshd" ]; systemd = [ "/base" ]; … }`                                                                                                                                                                                                                                                                                                                             |
| `links`          | 163 symlinks: every `bin` name of the six packages as `/usr/bin/<name>`, `/usr/bin/sh` → dash, systemd's directories as `farm` links, `libsystemd.so.0`, and the `.wants` links                                                                                                                                                                                                            |

The unit, as `iets eval --raw -E '(import ./examples/golconda.nix).composed.units."sshd.service"'`
prints it:

```ini
[Unit]
Description=sshd
After=network.target
After=golconda-var-sshd-hostkey.service
Wants=golconda-var-sshd-hostkey.service

[Service]
ExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/hostkey -o TrustedUserCAKeys=/usr/lib/sshd/ca.pub -o AuthorizedPrincipalsFile=/usr/lib/sshd/principals/%%u
LoadCredentialEncrypted=hostkey:sshd-hostkey.key
KillMode=process
User=root

[Install]
WantedBy=multi-user.target
```

Nothing in it is per-machine: the host key is `%d/hostkey`, a credential the machine makes.

## 4. The `/usr` tree

```sh
nix-build -E '(import ./examples/golconda.nix).usrTree'     # or: iets build … (a patched Nix daemon builds it)
```

`lib/usr-tree.nix` copies the closure of the six packages into `nix/store/`, makes the 163 symlinks
(relative, `farm` links expanded file by file), writes the units, `sysusers.d/golconda.conf`,
`tmpfiles.d/golconda.conf`, `os-release`, every file of `files`, and the artifacts
`lib/golconda/{config,schema,sbom,packages}.json`; then it checks the tree (no absolute symlink,
every dlopen link resolves, no setuid bit, only the allowed top-level directories). The output is
`golconda-usr-20261031.1`, a directory that is `/usr`
([Image artifacts](image.md#usr-tree-libusr-treenix)).

## 5. The image *(being built)*

From the `/usr` tree, `lib/image/` makes, one derivation each: the erofs image with every mtime set
to `20261031.1`'s epoch (`mkfs.erofs -T`); the verity hash tree, root hash and the signed
`usr-verity-sig`; the initrd (a second, smaller `/usr` tree: systemd, udev with the device-mapper
rules, veritysetup, repart); the UKI (kernel + initrd +
`usrhash=<root hash> console=tty0 console=ttyS0,115200`, Secure Boot and PCR 11 signed); and the GPT
disk with the ESP, the A slot filled, the B slot empty and no root partition. The artifacts are
named `server_20261031.1.{usr.raw,usr-verity.raw,usr-verity-sig.raw,efi}`
([Image artifacts](image.md)).

## 6. First boot

The disk boots in a VM with the host name as a credential:

```sh
qemu-system-x86_64 -bios OVMF.fd -drive file=server.img,format=raw \
  -smbios type=11,value=io.systemd.credential:system.hostname=web1 -serial stdio
```

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

## 7. Login

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

## 8. The next version

Change the document, set `version = "20261101.1"`, rebuild: the four artifacts land in
`https://updates.example.com/server/`, `systemd-sysupdate update` on the machine writes them to the
B slot and the ESP, and the next boot runs them; three failed boots fall back to A
([Updates](../design/updates.md)).
