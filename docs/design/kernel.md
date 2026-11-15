# Kernel

The kernel ships with Linux Security Modules (LSMs) enabled and configured for a signed, immutable
system. Lockdown, Yama and IPE are on, and IPE enforces its boot policy
([Trust: Execution policy](trust.md#execution-policy)). The configuration is in
`packages/kernel/golconda.config`; the UKI cmdline activates the LSMs
([Image artifacts: the kernel command line](../reference/image.md#the-kernel-command-line)).

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

The cmdline sets `ipe.enforce=1`. Every denial is an audit record (`type=1420`) in the kernel log,
with `rule="DEFAULT op=EXECUTE action=DENY"`; `/sys/kernel/security/ipe/success_audit` logs the
allowed ones too, with the rule that matched. The kernel must carry the key that signed the root
hash, or `/usr` is unsigned and nothing on it runs: see [Trust: Verity key](trust.md#2-verity-key).

### Verity signature trust

The verity root hash is signed; dm-verity verifies the signature when `/usr` is set up, before IPE
marks the volume `dmverity_signature`. It trusts the secondary keyring alone
(`DM_VERITY_VERIFY_ROOTHASH_SIG_SECONDARY_KEYRING`): the keys built into the kernel, and keys a
built-in key signed (`SECONDARY_TRUSTED_KEYRING_SIGNED_BY_BUILTIN`). Golconda builds in one key, the
`db` certificate of the image's key set (`SYSTEM_TRUSTED_KEYS`, a fixed path the build fills), and
adds none. The `db` key that signs the UKI also signs the verity root hash. Neither dm-verity nor
IPE policy updates trust the platform keyring, which the kernel fills from the firmware `db`
(`DM_VERITY_VERIFY_ROOTHASH_SIG_PLATFORM_KEYRING` and `IPE_POLICY_SIG_PLATFORM_KEYRING` off). So
each key set has its own kernel; why, and what that costs:
[Trust: Verity key](trust.md#2-verity-key).

The signature reaches dm-verity through the UKI cmdline
(`systemd.verity_usr_options=root-hash-signature=base64:`); why is in
[Trust: Verity key](trust.md#2-verity-key).

## Left out

An option that nothing in the image uses is off: it is code an attacker can reach, and no test
covers it.

- **vsock** (`CONFIG_VSOCKETS`): a host-to-guest socket without a network. Nothing listens on it,
  and it is where systemd's ssh generator would put a second sshd (the image does not have that
  generator, [Certificate login](../features/ssh-login.md#how-it-works)).
- **9P** (`CONFIG_NET_9P`): a file system shared by the host. The VM test does not share a
  directory.
- **`/proc/config.gz`** (`CONFIG_IKCONFIG`): nothing reads it. The package has the resolved config
  in `lib/modules/<version>/config`.

## Hangs and watchdogs

The soft and hard lockup detectors (the hard one on the perf NMI) and the hung task detector are
built in, and so are the watchdog drivers: QEMU's `i6300esb`, Intel's `iTCO_wdt` (through
`lpc_ich`), AMD's `sp5100_tco` and `softdog`. What a hang then does is the
[trial boot](boot.md#trial-boot) policy's.

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
