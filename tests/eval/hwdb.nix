# Checks of the compiled hardware database (packages/hwdb): /base links hwdb.bin into
# /usr/lib/udev, built from the server's selection of systemd's hwdb.d.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  mkSystemFixture,
  ...
}:
let
  inherit (builtins) all elem;
  path = "/usr/lib/udev/hwdb.bin";
  link = mkSystemFixture.composed.links.${path} or null;
  files = import ../../packages/hwdb/files.nix;
in
[
  (check "hwdb: /base links the compiled hwdb.bin into /usr/lib/udev" (
    link != null
    && link.kind == "explicit"
    && builtins.match ".*/lib/udev/hwdb.bin" link.target != null
    && (mkSystemFixture.composed.origins.links.${path} or [ ]) == [ "/base" ]
  ))
  (check "hwdb: it is a package of /base, not a build fragment" (
    (mkSystemFixture.composed.origins.packages.hwdb or [ ]) == [ "/base" ]
  ))
  (check "hwdb: modules.json lists no /image/hwdb fragment" (
    !(elem "/image/hwdb" mkSystemFixture.fragments)
  ))
  (check
    "hwdb: the selection keeps naming, IMDS, TPM2, vsock and PCI/USB names, no desktop input data"
    (
      all (f: elem f files) [
        "20-net-ifname.hwdb"
        "40-imds.hwdb"
        "60-tpm2.hwdb"
        "70-vsock.hwdb"
        "20-pci-vendor-model.hwdb"
        "20-pci-classes.hwdb"
        "20-usb-vendor-model.hwdb"
        "20-usb-classes.hwdb"
      ]
      && !(elem "60-keyboard.hwdb" files)
      && !(elem "20-OUI.hwdb" files)
    )
  )
]
