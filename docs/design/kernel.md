# Kernel

The kernel ships with Linux Security Modules (LSMs) enabled and configured for a signed, immutable
system. Status today: lockdown and Yama are on; IPE is in the kernel and on the cmdline but enforces
nothing yet ([Trust: Verity key](trust.md#2-verity-key)). The configuration is in
`packages/kernel/golconda.config`; the UKI cmdline activates the LSMs.

## LSM stack

The kernel cmdline sets `lsm=lockdown,yama,ipe,bpf`. This is the order in which security hooks run
(capability is always first and is not listed). Each LSM adds a layer:

| LSM      | What it enforces                                                                 |
| -------- | -------------------------------------------------------------------------------- |
| lockdown | Kernel self-protection: blocks `/dev/mem`, kexec, unsigned module loads, etc.    |
| yama     | ptrace restrictions: unprivileged processes cannot attach to each other          |
| ipe      | Execution only from dm-verity volumes with a signed root hash, or from initramfs |
| bpf      | BPF-based policy hooks for systemd's `RestrictFileSystems=` (phase 2)            |

## IPE (Integrity Policy Enforcement)

IPE decides which files may execute based on immutable properties of their origin. The boot policy
(`packages/kernel/ipe-boot-policy`) allows:

1. **Initramfs**: `boot_verified=TRUE` — the initramfs inside the UKI, which the kernel marks
   `boot_verified`.
1. **dm-verity volumes with a signed root hash**: `dmverity_signature=TRUE` — the `/usr` image.

This policy is compiled into the kernel (`CONFIG_IPE_BOOT_POLICY`). It denies execution from any
other source, including `/var`, `/tmp`, and unsigned verity volumes.

The cmdline sets `ipe.enforce=0` (permissive: denials are audited to the journal) until the verity
signing certificate is in a kernel keyring; then it becomes `1`. The key and its status are in
[Trust: Verity key](trust.md#2-verity-key).

### Verity signature trust

The verity root hash is signed; the kernel verifies the signature before allowing the volume. Two
keyrings can hold the signing certificate:

- **Platform keyring**: populated from the UEFI Secure Boot `db` at boot. The same certificate that
  signs the UKI can sign the verity root hash — one key for both.
- **Secondary keyring**: certificates signed by a key built into the kernel
  (`SECONDARY_TRUSTED_KEYRING_SIGNED_BY_BUILTIN`).

Which of the two Golconda uses is open. The image builder signs the verity root hash with its own
key today, and no keyring holds the certificate: see [Trust: Verity key](trust.md#2-verity-key).

## Lockdown

The cmdline sets `lockdown=integrity`. This is kernel self-protection: it blocks operations that
could modify the running kernel or bypass measured boot:

- `/dev/mem`, `/dev/kmem`, `/dev/port` writes
- kexec with an unsigned image (kexec is also disabled in the config)
- BPF program loading by unprivileged users
- debugfs writes
- unsigned module loads (modules are off, but defence-in-depth)

`confidentiality` mode would add hibernation blocking and ACPI table loading; `integrity` is enough
for the threat model.

## Yama

Yama restricts ptrace. The sysctl `kernel.yama.ptrace_scope=2` (set by `/security`) allows ptrace
only for processes with `CAP_SYS_PTRACE`. This blocks lateral movement via ptrace injection.

## Sysctl hardening

`/usr/lib/sysctl.d/50-golconda.conf` (from the `/security` module) applies at boot:

| sysctl                           | value | effect                                |
| -------------------------------- | ----- | ------------------------------------- |
| kernel.yama.ptrace_scope         | 2     | ptrace requires CAP_SYS_PTRACE        |
| kernel.kptr_restrict             | 2     | kernel pointers hidden from all users |
| kernel.dmesg_restrict            | 1     | dmesg requires CAP_SYSLOG             |
| kernel.unprivileged_bpf_disabled | 1     | BPF syscall requires CAP_BPF          |
| net.core.bpf_jit_harden          | 2     | BPF JIT hardened against spraying     |
| kernel.kexec_load_disabled       | 1     | kexec_load blocked (defence-in-depth) |

## Phase 2: BPF LSM

`CONFIG_BPF_LSM=y` is enabled. Phase 2 adds `CONFIG_DEBUG_INFO_BTF` (kernel size cost: 1–3 MB) and
rebuilds systemd with `bpf-framework=enabled`. This unlocks `RestrictFileSystems=` per service.

## Phase 3: AppArmor

Path-based MAC profiles generated from the typed service definitions. The research report is outside
the repository.
