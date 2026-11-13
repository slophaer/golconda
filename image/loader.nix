# systemd-boot on the ESP: its policy, and where the copies go
#
# The ESP carries the signed systemd-boot twice, as `bootctl install` lays it out: the primary
# copy `EFI/systemd/systemd-boot<arch>.efi` (bootctl's mark that systemd-boot is installed) and the
# removable-media path `EFI/BOOT/BOOT<ARCH>.EFI`, which firmware starts when no boot variable names
# a loader; Golconda writes no boot variable. The image builder writes both and `loader.conf`
# (lib/image/disk.nix); the running system keeps them equal to its /usr
# (golconda-loader-update.service, modules/base). See docs/design/bootloader.md.
{
  # The menu policy, loader.conf(5) of systemd v262.1. systemd-boot reads `\loader\loader.conf`
  # at the root of the ESP (src/boot/boot.c config_load_defaults), not under EFI/. The UKI under
  # EFI/Linux is found without an entry line. The menu does not wait and the editor is off: an
  # editor would let anyone at the console change the measured cmdline. In Setup Mode, `force`
  # enrols PK, KEK, db and dbx from enrolPath, also on hardware, and resets the machine; on
  # hardware it first warns for 15 seconds (a key aborts), in a virtual machine not
  # (src/boot/secure-boot.c, loader.conf(5); docs/design/bootloader.md). Outside Setup Mode the
  # files are not read.
  conf = ''
    # Golconda: image/loader.nix; docs/design/bootloader.md.
    timeout 0
    editor no
    secure-boot-enroll force
  '';

  # where the signer puts the Secure Boot variables (PK.auth, KEK.auth, db.auth, dbx.auth; the key
  # set's secureboot/auth, lib/image/enrol.nu): the set systemd-boot calls `auto`
  enrolPath = "loader/keys/auto";

  # where loader.conf goes, from the root of the ESP
  confPath = "loader/loader.conf";

  # the copy of `conf` in /usr: golconda-loader-update writes it back when the ESP's differs
  usrConfPath = "/usr/lib/golconda/loader.conf";
}
