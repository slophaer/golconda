# Scope

What a server operating system needs, and where Golconda places each: now, later, or out of scope by
design. A need that is not on this list has not been considered; one that is marked out of scope is
not forgotten, it is refused ([Principles](principles.md)).

## Now

| need                       | how                                                                                                                                                 | where                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| network                    | networkd; DHCP on every wired link by default, static addresses as `/network.networks`                                                              | `/network`                                              |
| DNS                        | resolved; per-link servers from DHCP, fallback servers as `/network.dns`                                                                            | `/network`                                              |
| time                       | timesyncd with the default pool, `/base.ntp` to change it; systemd's built-in clock epoch is the pin date (`time-epoch`), so the RTC's time is kept | `/base`                                                 |
| logs                       | journald only, retention bounded by `/base.journalMaxUse`                                                                                           | `/base`                                                 |
| host name                  | the bootstrap credential `system.hostname`, read by PID 1; DHCP's name without it                                                                   | [Boot](boot.md#bootstrap-credentials)                   |
| locale                     | `C.UTF-8` only; no `localed`, no other locale                                                                                                       | `/base`                                                 |
| provisioning               | systemd credentials from SMBIOS, qemu fw_cfg or the ESP; with `/imds`, systemd's import from a cloud's metadata; no cloud-init                      | [Boot](boot.md#bootstrap-credentials)                   |
| login                      | ssh as root with OpenSSH certificates from step-ca; keys for bootstrap; no password, no local login                                                 | `/services/sshd`                                        |
| secrets                    | vars: generated on the machine or pushed by the administrator, sealed to the TPM; rotation = push again                                             | `/vars`, [Trust](trust.md#secrets-and-vars)             |
| updates                    | sysupdate from `/system.updateSource`, A/B slots, boot counting, an OpenPGP-signed `SHA256SUMS`                                                     | `/system`, `image/sysupdate.nix`, [Updates](updates.md) |
| factory reset              | `FactoryReset=` on the root partition                                                                                                               | `image/repart.nix`                                      |
| serial console             | kernel output on `ttyS0`; no getty                                                                                                                  | `image/uki.nix`                                         |
| kernel command line        | fixed in the UKI and measured; no administrator edits                                                                                               | `image/uki.nix`                                         |
| disk growth                | the root partition grows to the disk on first boot (`GrowFileSystem=`)                                                                              | `image/repart.nix`                                      |
| time zone                  | `/factory.timezone`, a link into tzdata's `/usr/share/zoneinfo`, which `/base` ships                                                                | `/factory`                                              |
| CA store                   | one CA bundle in `/usr` (Mozilla roots plus `/trust.anchors`, minus `/trust.distrust`), linked into `/etc/ssl`                                      | [Trust](trust.md#3-ca-store)                            |
| Secure Boot, measured boot | signed UKIs, PCR 11 policies, TPM2-sealed credentials                                                                                               | [Boot](boot.md#secure-boot), [Trust](trust.md)          |
| hardening (sysctl)         | Yama, `kptr_restrict`, `dmesg_restrict`, no unprivileged BPF, no kexec                                                                              | `/security`                                             |
| execution policy           | IPE, lockdown and Yama in the kernel and the cmdline; IPE enforces, so `/usr` runs only from a verity volume with a verified signature              | `packages/kernel`, `/security`, [Kernel](kernel.md)     |
| Secure Boot enrolment      | the signer puts the deployment's signed `PK`, `KEK`, `db` and `dbx` on the ESP; systemd-boot enrols them in Setup Mode                              | [Boot loader](bootloader.md#enrolment)                  |
| keys on a token            | the signer takes the `db` and PCR keys from a PKCS#11 token; the release key is a file                                                              | [Trust](trust.md#keys-on-a-token)                       |
| trial boot                 | a counted boot that fails reboots into its next try: a panic, a PID 1 crash, `emergency.target`, an initrd hang, a failed health unit               | `/base`, [Boot](boot.md#trial-boot)                     |
| failed boots               | after 3 boots in a row that do not complete, the other slot boots; after 6, the machine halts                                                       | `/base`, [Boot](boot.md#failed-boots)                   |
| watchdog                   | PID 1 runs the hardware watchdog, or softdog where there is none; the kernel panics on a lockup or a hung task                                      | `/base`, [Kernel](kernel.md#hangs-and-watchdogs)        |
| update reboot              | `systemd-sysupdate-reboot.timer` in the window of `/system.updateReboot`, only when systemd-boot would start another entry                          | `/system`, [Updates](updates.md#activation)             |

## Later

| need                             | direction                                                                                                                                                                                                                     |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| remote logging                   | `systemd-journal-upload` over TLS to a collector; journal FSS for tamper evidence                                                                                                                                             |
| firewall                         | nftables (the kernel has it); `RestrictAddressFamilies=` in the sandbox tiers is not a firewall                                                                                                                               |
| monitoring, metrics              | an exporter as a service module; the journal is the only record                                                                                                                                                               |
| backup                           | the operator's job; the OS gives one state partition and `/var/lib/<service>` per service                                                                                                                                     |
| swap, zram                       | none in the image                                                                                                                                                                                                             |
| encrypted state                  | LUKS2 bound to the TPM (PCR 11 policy); the partition definition is ready for `Encrypt=tpm2`                                                                                                                                  |
| rollback protection              | pcrlock, policyref, key rotation; see [Trust](trust.md#rollback-weakness)                                                                                                                                                     |
| root-less operators              | operators as userdb records, ssh principal → user, `run0` gated by polkit on a few action ids                                                                                                                                 |
| workload identity                | one CA for SSH and X.509 with TPM device attestation; a renewal unit feeding systemd credentials                                                                                                                              |
| execution policy                 | the BPF LSM for `RestrictFileSystems=`, AppArmor profiles from the typed service                                                                                                                                              |
| debug access                     | a debug image or a sysext with tools and a getty; never in the production image                                                                                                                                               |
| hardware                         | firmware and kernel modules only when a target needs them (the kernel is monolithic)                                                                                                                                          |
| aarch64                          | an aarch64 image; it needs an aarch64 builder, and the build host has none                                                                                                                                                    |
| dbx updates on enrolled machines | an authenticated `dbx` append, signed by the deployment's KEK, written on a running machine; a machine gets the `dbx` of its key set's enrolment files once, at enrolment ([Boot loader: Enrolment](bootloader.md#enrolment)) |
| the release key on a token       | through PKCS#7 manifests (systemd v263) or an OpenPGP card ([Trust: Keys on a token](trust.md#keys-on-a-token))                                                                                                               |
| read-only `/etc`                 | a confext built from the image makes `/etc` read-only                                                                                                                                                                         |
| image diff                       | `golconda diff A B` compares the `config.json` of two built images                                                                                                                                                            |
| management console               | a web daemon with OIDC sign-in, deploy jobs and an audit log, a terminal UI, and commands that edit the document                                                                                                              |

## Out of scope by design

| not                  | because                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------- |
| per-human accounts   | identity is the certificate principal; service users come from sysusers only; no `useradd`, no shadow suite |
| cloud-init           | provisioning is systemd credentials; a cloud that cannot pass them passes a disk with a `.cred` on the ESP  |
| Nix on the machine   | the store is a build-time artifact; a configuration change is a new image                                   |
| overlays, overrides  | duplicates are errors; a module that wants another's result calls it                                        |
| local login          | no getty, no password; recovery is the other slot or a reflash ([Recovery](bootloader.md#recovery))         |
| a second of anything | one libc, toolchain, TLS stack, CA store, init, logger, network stack, shell                                |
| BIOS, desktops       | UEFI servers only                                                                                           |
