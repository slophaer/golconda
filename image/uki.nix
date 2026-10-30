# UKI (Unified Kernel Image) configuration
#
# Parameters for ukify build. The builder substitutes values at build time.
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
{ imageId }:
{
  # Kernel command line template
  # {usrhash} is substituted with the verity root hash at build time
  cmdlineTemplate = "usrhash={usrhash} systemd.volatile=no console=ttyS0 rw";

  # EFI output naming
  # {version} is the IMAGE_VERSION
  outputPattern = "${imageId}_{version}+3-0.efi";
  sourcePattern = "${imageId}_{version}.efi"; # For sysupdate (no boot count)

  # Secure Boot signing
  signWithSecureBoot = true;
  secureBootKeyPath = "db.key";
  secureBootCertPath = "db.crt";

  # PCR policy signing (for measured boot)
  # PCR 11 is measured by systemd-stub
  signWithPcr = true;
  pcrKeyPath = "pcr.key";
  pcrCertPath = "pcr.crt";
  # Phases to sign: enter-initrd, leave-initrd, sysinit, ready, shutdown, final
  pcrPhases = [
    "enter-initrd"
    "leave-initrd"
    "sysinit"
    "ready"
  ];
}
