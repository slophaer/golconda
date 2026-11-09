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
| the first ssh key (not Hetzner) | `ssh.authorized_keys.root` | systemd-tmpfiles-setup: `/root/.ssh/authorized_keys`, when the file is missing         |
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
with it the IMDS lock. Copy the lock into the file, and turn the DHCP host name off. On Hetzner
Cloud, where each server has a static IPv6 `/64` with no router advertisement, the user data for the
server's address is:

```json
{"systemd.credentials": [
  {"name": "ssh.authorized_keys.root", "text": "ssh-ed25519 AAAA... me\n"},
  {"name": "network.network.60-ipv6", "text": "[Match]\nType=ether\nKind=!*\n\n[Network]\nDHCP=ipv4\nIPv6AcceptRA=no\nAddress=2001:db8:1:2::1/64\nGateway=fe80::1\n\n[DHCPv4]\nUseHostname=no\n\n[Route]\nDestination=169.254.169.254\nType=prohibit\n\n[Route]\nDestination=169.254.169.254\nScope=link\nTable=0x7FFF0815\n\n[RoutingPolicyRule]\nFamily=ipv4\nFirewallMark=0x7FFF0815\nTable=0x7FFF0815\n"}
]}
```

with the server's own prefix in `Address=`. The three last sections are the lock that
`85-imds-early.network` holds: the prohibit route, and imdsd's route and rule by firewall mark.

### Hetzner Cloud

systemd 262's `40-imds.hwdb` has wrong paths for Hetzner: it asks for
`/hetzner/v1/metadata/public-keys/0` and `/hetzner/v1/metadata/userdata`, and Hetzner answers both
with 404, so the import fails. Hetzner serves the keys under `/hetzner/v1/metadata/` and the user
data at `/hetzner/v1/userdata`. `/imds` ships the right paths as data, the udev rule
`70-golconda-imds.rules`. systemd-imdsd reads its endpoint from the udev properties of the DMI
device, which `50-udev-default.rules` fills from hwdb. The rule runs after that, on the device whose
hwdb vendor is `hetzner-cloud` only, and sets the base URL `http://169.254.169.254/hetzner/v1`, the
keys `/metadata/hostname`, `/metadata/region`, `/metadata/availability-zone`,
`/metadata/public-ipv4` and `/userdata`, and no ssh key. The address stays hwdb's.

Why a rule: Golconda compiles one `hwdb.bin` at build time (`packages/hwdb`, linked by `/base`), so
a `hwdb.d` file would need that build and would be in every image. An `imds.*` credential or a
`systemd.imds.*` option would replace hwdb's entry on every cloud, not only on Hetzner.

Hetzner lists the ssh keys of the project only as one JSON array (`/metadata/public-keys`), which
systemd-imds cannot read. Give root's key in the user data, as the credential
`ssh.authorized_keys.root`. Drop the rule once systemd's hwdb has the right paths.

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
- `imds-hostname`, `imds-hetzner-layout`, `imds-ssh-key`, `imds-userdata-credential`, `imds-ipv6`,
  `imds-endpoint-locked` and `imds-dhcp-hostname` on a faked Hetzner Cloud (`--ssh-test --imds`):
  SMBIOS names Hetzner, and nothing else. The guest finds the endpoint by hwdb and `/imds`'s rule,
  and the harness serves it at `169.254.169.254` in Hetzner's layout.
- `imds-import-inactive`: without a cloud in DMI, the test image's `/imds` runs no import.

On a Hetzner Cloud server (2026-11-09, [What is proven](../proven.md#imds-on-hetzner-cloud)), with
`/imds` and no ESP credential: the import passed, the host name came from the metadata, the user
data's key logged in, the user data's `.network` file gave the IPv6 address in the first boot, and
the endpoint stayed locked.

## Limits

- A credential carries no secret. The ESP is not encrypted, and every process reads SMBIOS strings.
  Secrets are [vars](vars.md).
- With Secure Boot on and a TPM2, the guest refuses ESP credentials. That run fails.
- No marker covers a cloud's own OEM strings, or fw_cfg on real hardware.
- `/imds` takes no ssh key from Hetzner's metadata: it lists them only as a JSON array. The user
  data gives the key.
- No marker covers a real cloud's endpoint; Hetzner's ran by hand. Other clouds' hwdb entries have
  not run.
- v1 names two credentials. `--credential` writes others, but the docs name no reader for them.

## More

- [Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials) and
  [First boot](../design/boot.md#first-boot).
- [Hetzner Cloud](../reference/hetzner-cloud.md#4-the-machines-credentials) *(planned)*: the ESP
  route end to end.
- [Image artifacts](../reference/image.md): the `--esp-creds` test.
- [Trust: Secrets and vars](../design/trust.md#secrets-and-vars).
- [Login by ssh](ssh-login.md).
