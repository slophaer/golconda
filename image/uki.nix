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

  # PCR policy signing (for measured boot and credential decryption). Phases to sign, as
  # colon-separated string for ukify --phases
  # This covers the full boot path for LoadCredentialEncrypted= in services:
  #   enter-initrd  - measured when systemd-stub starts
  #   leave-initrd  - measured before pivot_root to real root
  #   sysinit       - measured when PID 1 reaches basic.target
  #   ready         - measured when PID 1 reaches multi-user.target
  #
  # A credential sealed with:
  #   systemd-creds encrypt --with-key=tpm2 --tpm2-public-key=<pub> --tpm2-public-key-pcrs=11
  # can be unsealed at any phase if that phase prefix is in the signature.
  pcrPhases = "enter-initrd:leave-initrd:sysinit:ready";

  # Rollback weakness: any UKI signed by the same key can unseal credentials.
  # Mitigations (see docs/design/trust.md):
  #   - systemd-pcrlock: binds to exact PCR values of one image
  #   - Key rotation: change signing key after security updates
  #   - policyref (systemd 262+): refuse policies signed for a different reference
}
