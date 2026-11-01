# systemd-boot on the ESP: its policy and where it goes
#
# The image builder writes loader.conf on the ESP (lib/image/disk.nix). See docs/design/boot.md.
{
  # The menu policy, loader.conf(5) of systemd v262.1. systemd-boot reads `\loader\loader.conf`
  # at the root of the ESP (src/boot/boot.c config_load_defaults), not under EFI/. The UKI under
  # EFI/Linux is found without an entry line. The menu does not wait and the editor is off: an
  # editor would let anyone at the console change the measured cmdline.
  conf = ''
    # Golconda: image/loader.nix; docs/design/bootloader.md.
    timeout 0
    editor no
  '';

  # where loader.conf goes, from the root of the ESP
  confPath = "loader/loader.conf";
}
