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

## Limits

- A credential carries no secret. The ESP is not encrypted, and every process reads SMBIOS strings.
  Secrets are [vars](vars.md).
- With Secure Boot on and a TPM2, the guest refuses ESP credentials. That run fails.
- No marker covers a cloud's own OEM strings, or fw_cfg on real hardware.
- v1 names two credentials. `--credential` writes others, but the docs name no reader for them.

## More

- [Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials) and
  [First boot](../design/boot.md#first-boot).
- [Hetzner Cloud](../reference/hetzner-cloud.md#4-the-machines-credentials) *(planned)*: the ESP
  route end to end.
- [Image artifacts](../reference/image.md): the `--esp-creds` test.
- [Trust: Secrets and vars](../design/trust.md#secrets-and-vars).
- [Login by ssh](ssh-login.md).
