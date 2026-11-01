# Deploying to Hetzner Cloud

This page is the procedure for one Golconda machine on a Hetzner Cloud server: build an image for a
host without Secure Boot, put the machine's host name and ssh key on its ESP, write the disk from
the rescue system, and update it. *(not yet run on Hetzner)*: every step is proven in QEMU on plain
OVMF without Secure Boot (`scripts/boot-test --esp-creds` without `--secure-boot`); none has run on
a Hetzner server.

What Hetzner Cloud gives and lacks, and what Golconda does about it:

| Hetzner Cloud                                    | Golconda                                                                       |
| ------------------------------------------------ | ------------------------------------------------------------------------------ |
| UEFI on the CPX, CCX and CAX types (CX: BIOS)    | UEFI only; take a UEFI type                                                    |
| no Secure Boot                                   | `/system.secureBoot = false`: the kernel carries the `db` certificate          |
| no TPM                                           | vars seal to the host key alone ([Trust](../design/trust.md#secrets-and-vars)) |
| user data and ssh keys for cloud-init (metadata) | no cloud-init: the host name and ssh key are credentials on the ESP            |
| a console that is a screen (VNC)                 | the kernel's console and the journal on the framebuffer (`tty0`, `tty1`)       |
| no image upload                                  | write the disk from the rescue system                                          |
| virtio-scsi disk, virtio-net, DHCPv4             | built into the kernel; DHCP on every wired link (`/network`)                   |

What `secureBoot = false` costs: nothing checks the UKI before it runs. Whoever can write the ESP
(the provider, or anyone with root on the machine) can replace the kernel, and with it the key that
checks `/usr`. IPE still refuses every executable outside the signed `/usr`, and the kernel still
checks the `/usr` signature, so a changed `/usr` alone does not run
([Trust: Verity key](../design/trust.md#2-verity-key)).

## 1. Keys and the build host

The keys are the ones of [Making a release](release.md): `scripts/make-keys /srv/golconda-keys`. The
`secureboot/` pair signs the UKI (which no firmware checks here) and `/usr`; the kernel built for
this image trusts `secureboot/db.crt`. The build host is the one of [Build host](build-host.md).

## 2. The document

```toml
["/system"]
name = "web"
version = "20261101.1"
secureBoot = false
updateSource = "https://updates.example.com/web/"

["/services/sshd"]
port = 22
```

No `authorizedKeys`: the key comes from the ESP in step 4, so one image serves every machine. Serve
the update source over HTTPS: sysupdate does not verify a signature on the index in v1
(`Verify=no`), and without Secure Boot a UKI served by someone else would boot.

## 3. Build

```sh
iets build -E '((import ./default.nix).lib.mkImage {
  config = ./web.toml;
  keys = "/srv/golconda-keys";
}).disk'
```

The kernel is built again for this image: its built-in keyring holds `db.crt`. The output holds
`disk.raw` and `release/`.

## 4. The machine's credentials

Copy the disk (the store copy is read-only) and write the credentials onto its ESP:

```sh
cp --sparse=always <out>/disk.raw web1.raw
scripts/provision-esp web1.raw --hostname web1 --authorized-keys ~/.ssh/id_ed25519.pub
```

`scripts/provision-esp` writes `loader/credentials/system.hostname.cred` and
`loader/credentials/ssh.authorized_keys.root.cred`, each in the `systemd-creds` envelope with the
null key: the machine has no key of its own yet. systemd-stub passes them to the initrd; PID 1 takes
the host name from them at every boot, and `systemd-tmpfiles` writes `/root/.ssh/authorized_keys`
from the key at first boot. systemd accepts a null-key credential when Secure Boot is off or there
is no TPM ([Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials)); both hold here.
The ESP is not encrypted: put no secret in a credential.

## 5. Create the server and write the disk

With the [`hcloud` CLI](https://github.com/hetznercloud/cli) and a project token
(`hcloud context create golconda`):

```sh
hcloud ssh-key create --name me --public-key-from-file ~/.ssh/id_ed25519.pub
hcloud server create --name web1 --type cpx21 --image debian-12 --location fsn1 --ssh-key me
hcloud server enable-rescue web1 --ssh-key me
hcloud server reboot web1
IP=$(hcloud server ip web1)
```

The Debian image only gets the server created; the disk is overwritten next.
`hcloud server-type list` shows the types; take a CPX or CCX one. In the rescue system, check that
the server boots by UEFI before writing:

```sh
ssh root@$IP 'test -d /sys/firmware/efi && echo UEFI || echo BIOS'
```

Then write the disk and reboot. The rescue system is used for one boot only, so the reboot starts
the disk:

```sh
gzip -1 -c web1.raw | ssh root@$IP 'gunzip | dd of=/dev/sda bs=4M conv=fsync && reboot'
```

## 6. First boot

Watch it in the Cloud Console (or `hcloud server request-console web1`): the screen shows the
kernel's messages and the journal. On the first boot repart makes the root partition in the rest of
the disk and moves the GPT's backup header to its end, firstboot runs without a prompt, and the
health units bless the entry ([Boot: First boot](../design/boot.md#first-boot)).

```sh
ssh-keygen -R $IP            # the rescue system's host key
ssh root@$IP hostname        # web1
ssh root@$IP systemctl --failed
```

## 7. Updates

Change `version` in the document, build again, and publish the new `release/` directory at
`updateSource` ([Making a release: The release directory](release.md#4-the-release-directory)).
`systemd-sysupdate-update.timer` on the machine installs it into the B slots and the ESP; the next
boot runs it, and three failed boots return to the old slot ([Updates](../design/updates.md)). To
update at once: `ssh root@$IP systemctl start systemd-sysupdate-update.service`, then reboot.

## Not proven

- Any step on a Hetzner server: the firmware, the disk and network devices, the console, the
  metadata the server does not read.
- HTTPS as the update source: the update test serves HTTP (`scripts/boot-test --next`).
- IPv6: Hetzner assigns each server a `/64`; whether router advertisements reach it, or the address
  needs a static `/network` definition, is not checked.
