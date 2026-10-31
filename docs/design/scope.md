# Scope

What a server operating system needs, and where Golconda stands on each: in v1, after v1, or out of
scope by design. A need that is not on this list has not been considered; one that is marked out of
scope is not forgotten, it is refused ([Principles](principles.md)).

## v1

| need                       | how                                                                                                                                 | today                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| network                    | networkd; DHCP on every wired link by default, static addresses as `/network.networks`                                              | `/network`                                                                                          |
| DNS                        | resolved; per-link servers from DHCP, fallback servers as `/network.dns`                                                            | `/network`                                                                                          |
| time                       | timesyncd with the default pool, `/base.ntp` to change it                                                                           | `/base`                                                                                             |
| logs                       | journald only, retention bounded by `/base.journalMaxUse`                                                                           | `/base`                                                                                             |
| host name                  | the bootstrap credential `system.hostname`, read by systemd-firstboot; DHCP's name without it                                       | [Boot](boot.md#bootstrap-credentials)                                                               |
| locale                     | `C.UTF-8` only; no `localed`, no other locale                                                                                       | `/base`                                                                                             |
| provisioning               | systemd credentials from SMBIOS, qemu fw_cfg or the ESP; no cloud-init                                                              | [Boot](boot.md#bootstrap-credentials)                                                               |
| login                      | ssh as root with OpenSSH certificates from step-ca; keys for bootstrap; no password, no local login                                 | `/services/sshd`                                                                                    |
| secrets                    | vars: generated on the machine or pushed by the administrator, sealed to the TPM; rotation = push again                             | `/vars`, [Trust](trust.md#secrets-and-vars)                                                         |
| updates                    | sysupdate from `/system.updateSource`, A/B slots, boot counting                                                                     | transfers rendered; artifacts built; no update run yet                                              |
| factory reset              | `FactoryReset=` on the root partition                                                                                               | `image/repart.nix`                                                                                  |
| serial console             | kernel output on `ttyS0`; no getty                                                                                                  | `image/uki.nix`                                                                                     |
| kernel command line        | fixed in the UKI and measured; no administrator edits                                                                               | `image/uki.nix`                                                                                     |
| disk growth                | the root partition grows to the disk on first boot (`GrowFileSystem=`)                                                              | `image/repart.nix`                                                                                  |
| time zone                  | `/factory.timezone`, a link to `/usr/share/zoneinfo`; no zoneinfo package yet, so the link dangles (v1 gap)                         | `/factory`                                                                                          |
| CA store                   | one p11-kit trust path in `/etc/ssl`                                                                                                | *(planned)*: [Trust](trust.md#3-ca-store-planned)                                                   |
| Secure Boot, measured boot | signed UKIs, PCR 11 policies, TPM2-sealed credentials                                                                               | signed in the image chain; enrolment and enforcement not proven: [Boot](boot.md), [Trust](trust.md) |
| hardening (sysctl)         | Yama, `kptr_restrict`, `dmesg_restrict`, no unprivileged BPF, no kexec                                                              | `/security`                                                                                         |
| execution policy           | IPE, lockdown and Yama in the kernel and the cmdline; IPE permissive (`ipe.enforce=0`) until the kernel checks the verity signature | `packages/kernel`, `/security`, [Kernel](kernel.md)                                                 |

## After v1

| need                  | direction                                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------ |
| remote logging        | `systemd-journal-upload` over TLS to a collector; journal FSS for tamper evidence                |
| firewall              | nftables (the kernel has it); `RestrictAddressFamilies=` in the sandbox tiers is not a firewall  |
| monitoring, metrics   | journal only in v1; an exporter is a service module later                                        |
| backup                | the administrator's; the OS gives one state partition and `/var/lib/<service>` per service       |
| swap, zram            | none in v1                                                                                       |
| secrets rotation tool | the deploy tool that pushes and seals admin vars; the on-machine side exists                     |
| encrypted state       | LUKS2 bound to the TPM (PCR 11 policy); the partition definition is ready for `Encrypt=tpm2`     |
| rollback protection   | pcrlock, policyref, key rotation; see [Trust](trust.md#rollback-weakness)                        |
| update verification   | a signed `SHA256SUMS` manifest for sysupdate (`Verify=no` in v1)                                 |
| root-less operators   | operators as userdb records, ssh principal → user, `run0` gated by polkit on a few action ids    |
| workload identity     | one CA for SSH and X.509 with TPM device attestation; a renewal unit feeding systemd credentials |
| execution policy      | enforcing IPE, the BPF LSM for `RestrictFileSystems=`, AppArmor profiles from the typed service  |
| debug access          | a debug image or a sysext with tools and a getty; never in the production image                  |
| hardware              | firmware and kernel modules only when a target needs them (monolithic kernel in v1)              |
| aarch64 images        | the cross-compiled `/usr` tree builds today; the bootable image follows the x86_64 one           |

## Out of scope by design

| not                  | because                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------- |
| per-human accounts   | identity is the certificate principal; service users come from sysusers only; no `useradd`, no shadow suite |
| cloud-init           | provisioning is systemd credentials; a cloud that cannot pass them passes a disk with a `.cred` on the ESP  |
| Nix on the machine   | the store is a build-time artifact; a configuration change is a new image                                   |
| overlays, overrides  | duplicates are errors; a module that wants another's result calls it                                        |
| local login          | no getty, no password; recovery is the other slot or a reflash                                              |
| a second of anything | one libc, toolchain, TLS stack, CA store, init, logger, network stack, shell                                |
| BIOS, desktops       | UEFI servers only                                                                                           |
