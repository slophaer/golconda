# Checks of the compiled hardware database (lib/image/hwdb.nix): mkSystem links hwdb.bin into
# /usr/lib/udev, built from the server's selection of systemd's hwdb.d.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  imageLib,
  mkSystemFixture,
  ...
}:
let
  inherit (builtins) all elem;
  link = mkSystemFixture.composed.links."/usr/lib/udev/hwdb.bin" or null;
in
[
  (check "hwdb: mkSystem links the compiled hwdb.bin into /usr/lib/udev" (
    link != null && link.kind == "explicit" && builtins.match ".*/hwdb.bin" link.target != null
  ))
  (check "hwdb: the selection keeps naming, IMDS, TPM2 and vsock, and no desktop input data" (
    all (f: elem f imageLib.hwdbFiles) [
      "20-net-ifname.hwdb"
      "40-imds.hwdb"
      "60-tpm2.hwdb"
      "70-vsock.hwdb"
    ]
    && !(elem "60-keyboard.hwdb" imageLib.hwdbFiles)
    && !(elem "20-usb-vendor-model.hwdb" imageLib.hwdbFiles)
  ))
]
