# Only signed code runs

The kernel runs a program only if it comes from the signed `/usr` (or the initramfs). A program that
an intruder copies to `/var` or `/tmp` gets `Permission denied`. The rule lives in the kernel and
the signed boot image, so a service cannot switch it off.

## How it works

- **IPE.** Integrity Policy Enforcement (IPE) is a Linux security module. Golconda compiles in a
  boot policy (`packages/kernel/ipe-boot-policy`) that denies execution by default. It allows two
  sources: the initramfs (`boot_verified=TRUE`) and a dm-verity volume with a signed root hash
  (`dmverity_signature=TRUE`). The policy trusts the signature, not one root hash, so a new image
  needs no new kernel. The same policy denies firmware, kernel modules, kexec images and X.509
  loads.
- **It enforces from the first boot.** The kernel command line sets `ipe.enforce=1`. The kernel has
  checked the `/usr` signature against the firmware `db` before IPE marks the volume.
- **Lockdown.** `lockdown=integrity` blocks `/dev/mem` writes, unsigned kexec and unsigned module
  loads. The kernel has no modules and no kexec.
- **Yama.** It restricts ptrace.
- **Sysctl hardening.** `/security` installs `/usr/lib/sysctl.d/50-golconda.conf`. It sets
  `kernel.yama.ptrace_scope=2`, `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1`,
  `kernel.unprivileged_bpf_disabled=1`, `net.core.bpf_jit_harden=2` and
  `kernel.kexec_load_disabled=1`.
- **All of it is fixed.** The LSM order `lsm=lockdown,yama,ipe,bpf` sits in the UKI command line,
  which is signed and measured. No administrator edits it.

## Using it

There is nothing to configure. `/security` is built in. Look at the result on a running machine:

```sh
sysctl kernel.yama.ptrace_scope               # 2
cat /sys/kernel/security/ipe/success_audit    # 1 logs allowed runs too
```

A denial is an audit record in the kernel log (`type=1420`):
`rule="DEFAULT op=EXECUTE action=DENY"`. An allowed run from `/usr` shows
`rule="op=EXECUTE dmverity_signature=TRUE action=ALLOW"`.

## Status

The firmware `db` must hold the signing certificate. Without it `/usr` activates unsigned, IPE
denies PID 1's re-exec after switch-root, and the machine stops with "Failed to execute /sbin/init".
So the boot test needs `--secure-boot`.

A boot that reaches `multi-user.target` with `ipe.enforce=1` proves that the kernel accepts the
signature and runs `/usr`. The proof table has no marker of its own for this
([What is proven](../proven.md)). The same holds without Secure Boot (`image-smoke-test-nosb`),
where the kernel's built-in key replaces the firmware `db`. `ipe-denies-copy` (`--ssh-test`, with
and without Secure Boot) copies `/usr`'s shell to `/var/tmp` and runs it: the exec fails with
`Permission denied`, and the kernel logs IPE's `DEFAULT op=EXECUTE action=DENY` for that path. Eval
tests check the command line, the kernel options and the policy text.

## Limits

- Phase 2, the BPF LSM for `RestrictFileSystems=`, and phase 3, AppArmor profiles from the typed
  service, are *(after v1)*. `CONFIG_BPF_LSM=y` is on, nothing uses it yet. SELinux is rejected.
- A rotated `db` key needs new images and new firmware enrolment.
- Without Secure Boot, whoever can write the ESP can replace the kernel and so the key that checks
  `/usr` ([Secure Boot and measured boot](measured-boot.md)).
- Only QEMU on x86_64 has run.

## More

- [Kernel: LSM stack](../design/kernel.md#lsm-stack),
  [IPE](../design/kernel.md#ipe-integrity-policy-enforcement),
  [Lockdown](../design/kernel.md#lockdown), [Yama](../design/kernel.md#yama) and
  [Sysctl hardening](../design/kernel.md#sysctl-hardening)
- [Trust: execution policy](../design/trust.md#execution-policy) and
  [verity key](../design/trust.md#2-verity-key)
- [The kernel command line](../reference/image.md#the-kernel-command-line)
- [A read-only, verified /usr](verified-usr.md)
