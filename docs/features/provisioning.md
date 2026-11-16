# Provisioning without cloud-init

One image serves every machine. The host name and the root ssh key arrive at first boot as systemd
credentials, from the hypervisor, the firmware or the ESP (EFI System Partition). The image has no
cloud-init, no agent and no per-machine file.

## How it works

Two bootstrap credentials exist:

| credential                 | read by                | what it sets                                                                |
| -------------------------- | ---------------------- | --------------------------------------------------------------------------- |
| `system.hostname`          | PID 1                  | the host name, at every boot                                                |
| `ssh.authorized_keys.root` | systemd-tmpfiles-setup | `/root/.ssh/authorized_keys`, which sshd reads through `AuthorizedKeysFile` |

Three delivery routes work:

- **SMBIOS**: a DMI type 11 OEM string, `io.systemd.credential:<name>=<value>`. On a cloud, use what
  the provider exposes as OEM strings.
- **qemu fw_cfg**: `-fw_cfg name=opt/io.systemd.credentials/system.hostname,string=web1`.
- **ESP**: `loader/credentials/<name>.cred` files. systemd-stub passes them to the initrd.

An ESP credential must be in the `systemd-creds` envelope. The machine has no host key before first
boot, so you encrypt the file with the null key (`--with-key=null`).

The null-key policy: `systemd.credentials_boot_policy=relaxed`, the default, accepts a null-key
credential when Secure Boot is off or the machine has no TPM2. With Secure Boot on and a TPM2
present, PID 1 refuses it. Anyone who can write the ESP could otherwise plant a credential that the
measured boot never vouched for. On such a machine use SMBIOS or fw_cfg.

PID 1 imports SMBIOS and fw_cfg credentials at every boot with no such check, also with Secure Boot
and a TPM2. A credential such as `tmpfiles.extra` writes files as root. So whoever sets SMBIOS or
fw_cfg (the hypervisor, or a BMC on hardware) is root on the machine, and the vars unseal.

PID 1 takes the host name from `systemd.hostname=` on the command line, then `/etc/hostname`, then
the credential, then the fallback `golconda`. Nothing writes `/etc/hostname` from `system.hostname`,
so an SMBIOS credential wins at every boot. systemd-firstboot writes it from `firstboot.hostname`,
which `scripts/provision-esp --hostname` adds.

An ESP credential holds for one boot: `golconda-esp-credentials.service` removes it from the ESP
once the first boot applied it, so a factory reset or a later boot does not apply it again
([Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials)).

On first boot, `systemd-repart` makes the root partition, PID 1 sets the host name, and
`systemd-firstboot` runs with `--mute-console=yes`, so it never prompts. tmpfiles writes the root
key.

### From cloud metadata (`/imds`)

With a `["/imds"]` table, the image also reads the cloud's instance metadata service (IMDS) through
systemd-imds, and systemd's own `systemd-imds-import.service` runs. systemd-imds-generator finds the
cloud by hwdb (Hetzner, AWS, GCP, Azure and others); on any other machine no import runs. The import
runs in the host, once the network is online and before `sysinit.target` and
`systemd-tmpfiles-setup.service`. It writes credentials to `/run/credstore`, and the usual readers
take them:

| IMDS gives                      | credential                 | read by                                                                                |
| ------------------------------- | -------------------------- | -------------------------------------------------------------------------------------- |
| the host name                   | `firstboot.hostname`       | systemd-firstboot, on the first boot: it writes `/etc/hostname`                        |
| the ssh keys                    | `ssh.authorized_keys.root` | systemd-tmpfiles-setup: `/root/.ssh/authorized_keys`, when the file is missing         |
| the public addresses            | none                       | resolved: local records for `_public`                                                  |
| user data `systemd.credentials` | each name it lists         | any unit that imports that name (`tmpfiles.*`, `login.*`, `firstboot.*`, `network.*`…) |

The host name lands in `/etc/hostname`, which PID 1 reads before the `system.hostname` credential:
on a machine with both, the IMDS name wins from the second boot on. No DHCP lease sets the host
name: `/imds` turns `UseHostname=` off in every `.network` file. A user data credential reaches the
units that start after the import. `sysusers.extra` misses it, as sysusers runs before the network
is online. The user data is measured into PCR 12.

`network.netdev.*`, `network.link.*` and `network.network.*` credentials from the user data take
effect in the same boot: `golconda-imds-network.service` runs `systemd-network-generator` again
after the import, then `networkctl reload`. A `.network` file from the user data replaces
`85-imds-early.network` on the links it matches, and with it the lock of `imds-network=locked`. So
`/imds` holds the lock on `lo` as well (`10-golconda-imds-lock.network`): only imdsd reaches the
IPv4 and IPv6 endpoints of systemd 262.1's `40-imds.hwdb`. The IPv6 rules need
`CONFIG_IPV6_MULTIPLE_TABLES=y`, which Golconda's kernel sets. A systemd update that adds an IPv6
endpoint to the hwdb fails the `hwdb` package test until the lock names it. The user data needs
nothing of the lock; turn the DHCP host name off in it. The
[`/imds` module page](../reference/modules/generated/imds.md) lists the endpoints and the rules. On
Hetzner Cloud, where each server has a static IPv6 `/64` with no router advertisement, the user data
for the server's address is:

```json
{"systemd.credentials": [
  {"name": "ssh.authorized_keys.root", "text": "ssh-ed25519 AAAA... me\n"},
  {"name": "network.network.60-ipv6", "text": "[Match]\nType=ether\nKind=!*\n\n[Network]\nDHCP=ipv4\nIPv6AcceptRA=no\nAddress=2001:db8:1:2::1/64\nGateway=fe80::1\n\n[DHCPv4]\nUseHostname=no\n"}
]}
```

with the server's own prefix in `Address=`.

### Hetzner Cloud

systemd 262's `40-imds.hwdb` asks Hetzner for paths that answer 404, so the import fails.
`packages/systemd` patches the entry to Hetzner's paths (`hwdb-imds-hetzner.patch`), and
`packages/hwdb` compiles it into every image's `hwdb.bin`. Hetzner lists the server's ssh keys only
as one JSON array (`/metadata/public-keys`). Two more patches (`imds-ssh-key-json.patch`,
`hwdb-imds-hetzner-ssh-keys.patch`) add the well-known key `ssh-key-json` and name the array for it.
The import writes the keys as one line each to `ssh.authorized_keys.root`; it skips an entry that is
not a string or that has a control character. The import writes this credential before the user
data's credentials, so where the metadata has a key, a user data `ssh.authorized_keys.root` is
skipped. The patches go when systemd ships the fixes.

The metadata endpoint is plain HTTP without authentication. Whoever can answer on its address sets
the host name, root's ssh key and any credential, such as `tmpfiles.extra`. Opt in only where the
network to the endpoint is trusted, as it is when the hypervisor serves it, and put no secret in
user data. systemd is built with `imds-network=locked`: a prohibit route keeps every process but
`systemd-imdsd` from the endpoint, and imdsd answers root only. Without `/imds` the IMDS units stay
off, also on a cloud, and the command line keeps the generator from pulling the import
(`systemd.imds.import=0`).

## Using it

`scripts/provision-esp` writes the credentials onto the ESP of a disk image, in place:

```sh
cp --sparse=always <out>/disk.raw web1.raw
scripts/provision-esp web1.raw --hostname web1 --authorized-keys ~/.ssh/id_ed25519.pub
```

It also takes `--credential NAME=FILE`. It finds the ESP in the GPT and refuses a path in
`/nix/store`, so give it a copy. With qemu, use SMBIOS instead:

```sh
-smbios type=11,value=io.systemd.credential:system.hostname=web1
```

## Status

Proven: the rows of [What is proven](../proven.md) that name `hostname`, `esp-credentials-once`,
`imds-hostname`, `imds-lock-endpoints` and `imds-import-inactive`. The limits are below.

## Limits

- A credential carries no secret. The ESP is not encrypted, and every process reads SMBIOS strings.
  Secrets are [vars](vars.md).
- With Secure Boot on and a TPM2, the guest refuses ESP credentials. That run fails.
- An ESP credential holds for the first boot only. A `network.*` credential from the ESP configures
  that boot alone; a lasting network configuration belongs in the image or in SMBIOS.
- Whoever can write the ESP can still plant a credential where Secure Boot is off or no TPM2 is
  present; removal makes it a single, logged use.
- No marker covers a cloud's own OEM strings, or fw_cfg on real hardware.
- A user data `ssh.authorized_keys.root` is skipped where the metadata has a key. A bad entry in
  Hetzner's array has run in QEMU only.
- No marker covers a real cloud's endpoint; Hetzner's ran by hand. Other clouds' hwdb entries have
  not run.
- No marker shows that imdsd itself still reaches an IPv6 endpoint through the lock: QEMU's user
  network serves none. `imds-lock-endpoints` proves the refusal for every address; the eval test
  proves `Family=both` on imdsd's two mark rules. imdsd's IPv6 path has not run on a cloud.
- The lock names the endpoints of systemd 262.1's hwdb. OpenStack's IPv6 endpoint `fe80::a9fe:a9fe`
  is in systemd's main branch only and joins the lock with the update that ships it.
- Two bootstrap credentials have a named reader (the table above). `--credential` writes others, but
  the docs name no reader for them.

## More

- [Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials) and
  [First boot](../design/boot.md#first-boot).
- [Hetzner Cloud](../reference/hetzner-cloud.md#4-the-machines-credentials): the ESP route end to
  end.
- [Image artifacts](../reference/image.md): the `--esp-creds` test.
- [Trust: Secrets and vars](../design/trust.md#secrets-and-vars).
- [Login by ssh](ssh-login.md).
