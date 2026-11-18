# Deploying to Hetzner Cloud

This page is the procedure for one Golconda machine on a Hetzner Cloud server. It builds an image
for a host without Secure Boot, puts the machine's host name and ssh key on its ESP, writes the disk
from the rescue system, and updates it. The runs of this procedure by hand are in
[What is proven: Not proven](../proven.md#not-proven).

What Hetzner Cloud gives and lacks, and what Golconda does about it:

| Hetzner Cloud                                    | Golconda                                                                                                        |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| UEFI on the CPX and CCX types (CX: BIOS)         | UEFI only; take a UEFI type                                                                                     |
| no Secure Boot                                   | `/system.secureBoot = false`: the kernel carries the `db` certificate                                           |
| no TPM                                           | vars seal to the host key alone ([Trust](../design/trust.md#secrets-and-vars))                                  |
| user data and ssh keys for cloud-init (metadata) | no cloud-init: the host name and ssh key are credentials on the ESP, or come from the metadata with `["/imds"]` |
| a console that is a screen (VNC)                 | the kernel's console and the journal's info and higher on the framebuffer (`tty0`, `tty1`)                      |
| no image upload                                  | write the disk from the rescue system                                                                           |
| virtio-scsi disk, virtio-net, DHCPv4             | built into the kernel; DHCP on every wired link (`/network`)                                                    |
| IPv6: a static `/64`, no router advertisements   | a static `.network` file; with `["/imds"]`, a user data credential `network.network.*` (step 4)                 |

What `secureBoot = false` costs: nothing checks the UKI before it runs. Whoever can write the ESP
(the provider, or anyone with root on the machine) can replace the kernel, and with it the key that
checks `/usr`. IPE still refuses every executable outside the signed `/usr`, and the kernel still
checks the `/usr` signature, so a changed `/usr` alone does not run
([Trust: Verity key](../design/trust.md#2-verity-key)).

## 1. Keys and the build host

Get `scripts/` and `golconda` first ([Making a release: Get the tools](release.md#get-the-tools)).
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

The document sets no `authorizedKeys`. The key comes from the ESP in step 4, so one image serves
every machine. sysupdate checks the release key's signature on the index. This matters here, because
without Secure Boot nothing else would stop a UKI served by someone else. HTTPS still hides what the
machine fetches.

## 3. Build

```sh
golconda release build -f web.toml --keys /srv/golconda-keys
```

Nix builds the image unsigned, with the key set's public halves only. The signer signs it on this
host with the private keys where they lie
([Making a release: Build and sign](release.md#2-build-and-sign)).

The kernel is built again for this image: its built-in keyring holds `db.crt`. Its config is the
same for every key set. With jig's compile cache (`jigd`) after one such build, only the certificate
object and the compressed kernel's wrapper compile again, and the kernel relinks. The output holds
`disk.raw` and `release/`.

## 4. The machine's credentials

Copy the disk (the store copy is read-only) and write the credentials onto its ESP:

```sh
cp --sparse=always <out>/disk.raw web1.raw
scripts/provision-esp web1.raw --hostname web1 --authorized-keys ~/.ssh/id_ed25519.pub
```

`scripts/provision-esp` writes `loader/credentials/system.hostname.cred`, `firstboot.hostname.cred`
and `ssh.authorized_keys.root.cred`, each in the `systemd-creds` envelope with the null key, because
the machine has no key of its own yet. systemd-stub passes them to the initrd. PID 1 takes the host
name from them, systemd-firstboot writes it to `/etc/hostname`, and `systemd-tmpfiles` writes
`/root/.ssh/authorized_keys` from the key, all at first boot. Then
`golconda-esp-credentials.service` removes the three files from the ESP, because they hold for one
boot. systemd accepts a null-key credential when Secure Boot is off or there is no TPM
([Boot: Bootstrap credentials](../design/boot.md#bootstrap-credentials)). Both hold here, so whoever
can write the disk can plant one ([Trust: The ESP](../design/trust.md#the-esp)). The ESP is not
encrypted: put no secret in a credential.

Or put `["/imds"]` in the document and write nothing to the ESP. The host name and the ssh keys the
server was created with then come from Hetzner's metadata. The user data can carry more credentials,
such as the static IPv6 address as `network.network.60-ipv6` (`Address=<prefix>::1/64`,
`Gateway=fe80::1`, `DHCP=ipv4`). A user data `ssh.authorized_keys.root` is skipped when the server
has keys ([Provisioning: Cloud metadata](../features/provisioning.md#hetzner-cloud)). The prefix is
known once the server exists: give the user data with `hcloud server rebuild --user-data-from-file`
before step 5's rescue boot.

## 5. Create the server and write the disk

With the [`hcloud` CLI](https://github.com/hetznercloud/cli) (`packages.x86_64-linux.hcloud`) and a
project token (`hcloud context create golconda`, or `HCLOUD_TOKEN`):

```sh
hcloud ssh-key create --name me --public-key-from-file ~/.ssh/id_ed25519.pub
hcloud server create --name web1 --type cpx12 --image debian-12 --location fsn1 --ssh-key me
hcloud server enable-rescue web1 --ssh-key me
hcloud server reboot web1
IP=$(hcloud server ip web1)
```

The Debian image only gets the server created; the disk is overwritten next. The disk must be larger
than `disk.raw`: 22.3 GB with the two 10 GiB `/usr` slots, so a type with a 20 GB disk (`cpx02`) is
too small. `hcloud server-type list` shows the types, and `hcloud server-type describe <type>` shows
where each can be ordered. `cpx12` has 2 vCPU, 2 GB and 40 GB. In the rescue system, check that the
server boots by UEFI before writing:

```sh
ssh root@$IP 'test -d /sys/firmware/efi && echo UEFI || echo BIOS'
```

Then write the disk and reboot. The rescue system is used for one boot only, so the reboot starts
the disk:

```sh
gzip -1 -c web1.raw | ssh root@$IP 'gunzip | dd of=/dev/sda bs=4M conv=fsync && reboot'
```

The rescue system's `reboot` prints `Failed to connect to system scope bus via local transport` and
reboots all the same.

## 6. First boot

Watch it in the Cloud Console (or `hcloud server request-console web1`): the screen shows the
kernel's messages and the journal. On the first boot repart makes the state partition in the rest of
the disk and moves the GPT's backup header to its end. firstboot runs without a prompt, and the
health units bless the entry ([Boot: First boot](../design/boot.md#first-boot)).

```sh
ssh-keygen -R $IP            # the rescue system's host key
ssh root@$IP hostname        # web1
ssh root@$IP systemctl --failed
```

The clock is right from the first boot. systemd's built-in epoch (`time-epoch`) is the date of its
pin, so PID 1 keeps the firmware's time, and `systemd-timesyncd` then syncs it.

## 7. Updates

Run `golconda release build` again: it picks the next version, writes it into the document and
commits it. Publish the new `release/` directory at `updateSource`
([Making a release: Publish the release directory](release.md#3-publish-the-release-directory)).
`systemd-sysupdate-update.timer` on the machine installs it into the B slots and the ESP; the next
boot runs it, and three failed boots return to the old slot ([Updates](../design/updates.md)). To
update at once: `ssh root@$IP systemctl start --wait systemd-sysupdate-update.service`, then reboot.

A run started a few seconds after the publish can still read the old index through the CDN and
report `No update needed`; start it again. `golconda release publish --unrecorded` still needs a git
repository: pass `--repo` with one.

## Limits

- No test reads the console.
