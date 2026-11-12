# OVMF, edk2's UEFI firmware for QEMU's x86_64 machines, for scripts/boot-test. A development
# tool, not part of an image. Not built here: a pinned nightly build of edk2 master, from
# osdev0/edk2-ovmf-nightly-bins (a GitHub release each night; sources.toml pins one by its tag and
# the hash of its tarball, uptrack follows the newest). Building edk2 from source (its BaseTools,
# nasm, iasl) is a later step.
#
# Two variants, each a code and a variable-store flash image, kept as edk2 names them:
#   share/ovmf/secure-boot/  4 MB flash: Secure Boot, SMM (QEMU needs -machine smm=on and secure
#                            pflash) and TPM 2.0. The boot test's --secure-boot and --tpm runs
#   share/ovmf/plain/        2 MB flash: none of the three. The runs without Secure Boot (the nosb
#                            image, Hetzner Cloud's firmware)
# Both variable stores are empty templates: the boot test copies one and enrols its keys offline.
#
# Trust: these are third-party binaries. osdev0's workflow (.github/workflows/build.yml in that
# repository) clones edk2 master, applies its own small patch (for x86_64: a 1024x768 video mode
# and the USB mouse driver), and builds with kernel.org's crosstool GCC on GitHub's runners. The
# release names the edk2 commit, but nothing here rebuilds it to compare, and nothing signs it: the
# pin's hash shows only that the bytes are those of that release. It runs only in the test VM, as
# the firmware that checks the image's signatures, so a bad build makes the boot test pass or fail
# wrongly; it never reaches an image.
{ package }:
package {
  name = "ovmf";
  install = {
    "share/ovmf/secure-boot/OVMF_CODE.fd" = "ovmf-code-x86_64-secboot.fd";
    "share/ovmf/secure-boot/OVMF_VARS.fd" = "ovmf-vars-x86_64-secboot.fd";
    "share/ovmf/plain/OVMF_CODE.fd" = "ovmf-code-x86_64.fd";
    "share/ovmf/plain/OVMF_VARS.fd" = "ovmf-vars-x86_64.fd";
  };
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
  platforms.os = [ "linux" ];
}
