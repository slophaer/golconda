# UKI (Unified Kernel Image) configuration
#
# Parameters for ukify build: the cmdline template and the PCR phases. The builder
# (lib/image/uki.nix) names the file, and the keys come from its arguments.
#
# The UKI contains:
#   - EFI stub (linuxx64.efi.stub)
#   - Linux kernel (bzImage/vmlinuz)
#   - Initrd (systemd-based, built separately)
#   - Kernel command line (with usrhash)
#   - os-release
#   - SBAT metadata (.sbat): revocation metadata, not a signature
#   - PCR measurements (.pcrsig, signed by PCR key)
#
# The whole UKI is also signed with the Secure Boot db key, so the firmware accepts it.
#
# See docs/design/boot.md for the boot process.
{
  # Kernel command line template
  # {usrhash} is substituted with the verity root hash at build time
  # {usrhashSig}: the base64 PKCS#7 signature of that hash, from the usr-verity-sig partition.
  #   systemd-veritysetup hands it to the kernel (root-hash-signature=base64:), which checks it
  #   against its built-in db certificate, never the firmware db; IPE's dmverity_signature is
  #   true only for a volume the kernel verified. Without it /usr activates unsigned, silently.
  # console=tty0,ttyS0: the local console and the serial line, output only (no getty)
  # rw: the root partition carries the state (/var, /etc), and the initrd mounts it read-only
  # unless the cmdline says rw; gpt-auto's remount-rw drop-in reaches systemd-remount-fs.service
  # only after switch-root. PID 1 needs /etc writable before that: on the first boot /etc is
  # empty, it cannot write /etc/machine-id on a read-only root ("System cannot boot: Missing
  # /etc/machine-id and /etc/ is read-only"), systemd-pcrmachine.service then fails to measure
  # the machine ID, and its FailureAction=reboot-force reboots the machine, at every boot
  # (docs/proven.md). `rw` is an ordinary kernel parameter (gpt-auto passes it to the root mount),
  # not a workaround. /usr stays read-only by dm-verity whatever is said. Nothing about volatility
  # either (/var is on the root partition, systemd's default).
  # panic=10: a kernel panic reboots after 10 s instead of hanging, so a release whose kernel
  # panics loses a try and systemd-boot falls back (the trial boot policy, modules/base/parts/
  # trial-boot.nix; docs/design/boot.md). A cmdline value, not CONFIG_PANIC_TIMEOUT, so the
  # policy is in one place with the rest of the boot's parameters.
  # softlockup_panic=1 nmi_watchdog=panic hung_task_panic=1: a hang the kernel's detectors see (a
  # CPU stuck in the kernel for 20 s, with interrupts off for 10 s, a task blocked for 120 s;
  # packages/kernel/golconda.config) panics, and panic=10 reboots it. nmi_watchdog=panic sets
  # kernel.hardlockup_panic and keeps the NMI watchdog on: the kernel has no hardlockup_panic=.
  # Security parameters (see docs/design/kernel.md):
  #   lsm=lockdown,yama,ipe,bpf   LSM stack order (capability is always first)
  #   lockdown=integrity          kernel lockdown level (blocks kexec, /dev/mem, etc.)
  #   ipe.enforce=1               IPE enforces the boot policy: execution only from the initramfs
  #                               and from verity volumes whose signature the kernel verified.
  #                               Needs the signer in the firmware db: without it /usr is unsigned
  #                               and PID 1's switch-root re-exec is denied (docs/design/trust.md)
  # systemd.imds.import=0: systemd-imds-generator does not pull systemd-imds-import.service. Its
  # default pulls it into the initrd, which has no network here; /imds pulls it into the host
  # instead, on a cloud only (modules/imds), and without /imds it never runs.
  cmdlineTemplate = "usrhash={usrhash} systemd.verity_usr_options=root-hash-signature=base64:{usrhashSig} rw panic=10 softlockup_panic=1 nmi_watchdog=panic hung_task_panic=1 lsm=lockdown,yama,ipe,bpf lockdown=integrity ipe.enforce=1 systemd.imds.import=0 console=tty0 console=ttyS0,115200";

  # PCR policy signing (for measured boot and credential decryption): the phase paths to
  # sign. A phase path is the colon-separated chain of words systemd has measured into
  # PCR 11 up to one boot state (systemd-pcrphase.service(8)); the TPM policy of a sealed
  # credential matches the path the machine is on when it unseals. `systemd-measure
  # --phase=` takes ONE path per signature; with no `--phase=` it signs this default set
  # (measure-tool.c), and `ukify --phases=` takes several, split on commas or spaces.
  #
  # The four default states, because the policy is to allow unsealing from the initrd on
  # (for a LUKS unlock, later) and at service time:
  #   enter-initrd                                  the stub has measured the UKI
  #   enter-initrd:leave-initrd                     the initrd is done
  #   enter-initrd:leave-initrd:sysinit             basic initialization done; services
  #                                                 (sshd, after basic.target) start here
  #   enter-initrd:leave-initrd:sysinit:ready       after remote-fs, before user sessions
  #
  # One long chain "enter-initrd:leave-initrd:sysinit:ready" is ONE path: signing only it
  # permits unsealing only at `ready`, so a service that starts earlier cannot load its
  # credential in a valid measured boot. lib/image/uki.nu checks the built .pcrsig against
  # this list; docs/design/trust.md states the policy.
  pcrPhases = [
    "enter-initrd"
    "enter-initrd:leave-initrd"
    "enter-initrd:leave-initrd:sysinit"
    "enter-initrd:leave-initrd:sysinit:ready"
  ];

  # Rollback weakness: any UKI signed by the same key can unseal credentials.
  # Mitigations (see docs/design/trust.md):
  #   - systemd-pcrlock: binds to exact PCR values of one image
  #   - Key rotation: change signing key after security updates
  #   - policyref (systemd 262+): refuse policies signed for a different reference
}
