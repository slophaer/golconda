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
#   - Secure Boot signature (.sbat, signed by db key)
#   - PCR measurements (.pcrsig, signed by PCR key)
#
# See docs/design/boot.md for the boot process.
{
  # Kernel command line template
  # {usrhash} is substituted with the verity root hash at build time
  # console=tty0,ttyS0: the local console and the serial line, output only (no getty)
  # neither ro nor rw: gpt-auto mounts the root partition read-write only with no `ro`, and
  # /usr is read-only by dm-verity whatever is said; nothing about volatility either (/var is
  # on the root partition, systemd's default)
  # Security parameters (see docs/design/kernel.md):
  #   lsm=lockdown,yama,ipe,bpf   LSM stack order (capability is always first)
  #   lockdown=integrity          kernel lockdown level (blocks kexec, /dev/mem, etc.)
  #   ipe.enforce=0               IPE in permissive mode (denials are audited) until the verity
  #                               signing certificate is in a kernel keyring; then 1
  # The builder appends rdinit= (lib/image/initrd.nix says why)
  cmdlineTemplate = "usrhash={usrhash} lsm=lockdown,yama,ipe,bpf lockdown=integrity ipe.enforce=0 console=tty0 console=ttyS0,115200";

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
