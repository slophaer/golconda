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

PID 1 takes the host name from `systemd.hostname=` on the command line, then `/etc/hostname`, then
the credential, then the fallback `golconda`. Nothing writes `/etc/hostname`, so the credential
wins.

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
effect in the same boot, though `systemd-network-generator.service`, their reader, runs before
networkd. The import pulls in `golconda-imds-network.service`, which runs after it:

1. `systemd-imds-early-network.service` writes `85-imds-early.network` (DHCP and the IMDS lock), and
   networkd brings the link up.
1. `network-online.target`, then `systemd-imds-import.service`: the user data's credentials land in
   `/run/credstore`.
1. `golconda-imds-network.service` imports the `network.*` credentials, runs systemd's
   `systemd-network-generator` again (it writes `/run/systemd/network/<name>.network`), then
   `networkctl reload`, which configures each link whose file changed. All before `sysinit.target`.

A `.network` file from the user data replaces `85-imds-early.network` on the links it matches, and
with it the lock of `imds-network=locked`: the prohibit route to the endpoint and imdsd's route and
rule by firewall mark. So `/imds` holds the lock on `lo` as well, in
`10-golconda-imds-lock.network`, where no file for a link replaces it. Policy rules belong to no
link: imdsd's packets (firewall mark `0x7FFF0815`) look in imdsd's table first (priority 32100),
then in the main table (32101), and every other packet to `169.254.169.254` is refused (32102). The
user data needs nothing of the lock; turn the DHCP host name off in it. On Hetzner Cloud, where each
server has a static IPv6 `/64` with no router advertisement, the user data for the server's address
is:

```json
{"systemd.credentials": [
  {"name": "ssh.authorized_keys.root", "text": "ssh-ed25519 AAAA... me\n"},
  {"name": "network.network.60-ipv6", "text": "[Match]\nType=ether\nKind=!*\n\n[Network]\nDHCP=ipv4\nIPv6AcceptRA=no\nAddress=2001:db8:1:2::1/64\nGateway=fe80::1\n\n[DHCPv4]\nUseHostname=no\n"}
]}
```

with the server's own prefix in `Address=`.

### Hetzner Cloud

systemd 262's `40-imds.hwdb` has wrong paths for Hetzner: it asks for
`/hetzner/v1/metadata/public-keys/0` and `/hetzner/v1/metadata/userdata`, and Hetzner answers both
with 404, so the import fails. Hetzner serves the keys under `/hetzner/v1/metadata/` and the user
data at `/hetzner/v1/userdata`. `packages/systemd` patches the entry (`hwdb-imds-hetzner.patch`, a
commit prepared for systemd upstream) to the base URL `http://169.254.169.254/hetzner/v1`, the keys
`/metadata/hostname`, `/metadata/region`, `/metadata/availability-zone`, `/metadata/public-ipv4` and
`/userdata`, and no ssh key, and `packages/hwdb` compiles it into every image's `hwdb.bin`. The
patch goes when systemd ships the fix.

Hetzner lists the server's ssh keys only as one JSON array (`/metadata/public-keys`), and systemd
262 reads one plain key only. `packages/systemd` carries two more patches, also drafted for systemd
upstream: `imds-ssh-key-json.patch` adds the well-known key `ssh-key-json`, which the import writes
as one line per key, after the plain `ssh-key`, to `ssh.authorized_keys.root` (an entry that is not
a string, or that has a control character in it, is skipped with a warning);
`hwdb-imds-hetzner-ssh-keys.patch` names `/metadata/public-keys` for it in the Hetzner entry. Most
clouds' hwdb entries name only their first key. The import writes this credential before the user
data's credentials, so where the metadata has a key, a user data `ssh.authorized_keys.root` is
skipped.

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

The boot test proves this in QEMU ([What is proven](../proven.md)):

- `hostname` and `ssh-login` with the SMBIOS credential (`--ssh-test`).
- `hostname`, `esp-authorized-keys` and `ssh-login` with a key only the ESP holds
  (`--ssh-test --esp-creds`).
- `no-firstboot-prompt`: first boot finishes without a prompt.
- `imds-hostname`, `imds-hetzner-layout`, `imds-ssh-keys-json`, `imds-ssh-key-precedence`,
  `imds-userdata-credential`, `imds-ipv6`, `imds-endpoint-locked` and `imds-dhcp-hostname` on a
  faked Hetzner Cloud (`--ssh-test --imds`): SMBIOS names Hetzner, and nothing else. The guest finds
  the endpoint by hwdb alone, and the harness serves it at `169.254.169.254` in Hetzner's layout.
- `imds-import-inactive`: without a cloud in DMI, the test image's `/imds` runs no import.

On Hetzner Cloud (2026-11-09, [What is proven](../proven.md#on-hetzner-cloud)), the guide's run gave
the host name and the key by the ESP route, and without `/imds` no IMDS unit ran. With `/imds` and
no ESP credential, the current form ran: the hwdb patch, the lock on `lo` and the ssh keys from the
JSON array. The import passed, the host name came from the metadata, both project keys logged in,
the user data's `ssh.authorized_keys.root` was skipped, the user data's `.network` file (with no
lock in it) gave the IPv6 address in the first boot, and the endpoint stayed locked. All of it held
again after `systemctl reboot` and after a power cycle, with the clock right from the start
([What is proven: `/imds` on Hetzner Cloud](../proven.md#imds-on-hetzner-cloud)).

## Limits

- A credential carries no secret. The ESP is not encrypted, and every process reads SMBIOS strings.
  Secrets are [vars](vars.md).
- With Secure Boot on and a TPM2, the guest refuses ESP credentials. That run fails.
- No marker covers a cloud's own OEM strings, or fw_cfg on real hardware.
- A user data `ssh.authorized_keys.root` is skipped where the metadata has a key. A bad entry in
  Hetzner's array has run in QEMU only.
- No marker covers a real cloud's endpoint; Hetzner's ran by hand. Other clouds' hwdb entries have
  not run.
- The lock on `lo` covers `169.254.169.254` only. An endpoint on IPv6 (AWS also has `fd00:ec2::254`)
  is locked only while its link uses `85-imds-early.network`.
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
