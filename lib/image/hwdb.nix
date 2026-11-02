# lib/image/hwdb.nix: the compiled hardware database, /usr/lib/udev/hwdb.bin.
#
# hwdb { buildSystem; tool; systemd; } → derivation with hwdb.bin: `systemd-hwdb --usr update`
#   over the files of systemd's lib/udev/hwdb.d that a server reads (`files`), run with the
#   build host's systemd (`tool`) on the target's sources (`systemd`). The output is the same
#   bytes for the same inputs.
# hwdbFragment { hwdb; } → a /system fragment linking it to /usr/lib/udev/hwdb.bin; mkSystem
#   adds it (lib/system.nix).
#
# Why at build time: udev, the IMDS generator and networkctl read only hwdb.bin, never the
# sources, and systemd-hwdb-update.service would write it to /etc/udev on the machine at first
# boot (ConditionNeedsUpdate=/etc). With /usr/lib/udev/hwdb.bin present the service does nothing.
# Without any, every hwdb lookup fails with no error: the udev properties are missing.
#
# Why these files: the full database is 13.9 MB. The selection is 8.0 MB: the PCI and USB vendor,
# model and class names (ID_VENDOR_FROM_DATABASE, ID_MODEL_FROM_DATABASE: what udevadm info,
# networkctl and lsusb-style tools show for a device) and the few entries a server acts on. Left
# out: MAC address vendors (20-OUI, 3 MB of names for nothing a server reads) and the desktop
# input quirks (keyboards, mice, touchpads, sensors, cameras).
_:
let
  common = import ./common.nix { };
  usrPath = "/usr/lib/udev/hwdb.bin";
  files = [
    "20-dmi-id.hwdb" # chassis asset tags: what the IMDS generator matches with modalias
    "20-net-ifname.hwdb" # network interface naming
    "40-imds.hwdb" # cloud instance metadata endpoints, matched by DMI (Hetzner, AWS, GCP, ...)
    "60-tpm2.hwdb" # TPM2 device properties
    "70-vsock.hwdb" # vsock on Hyper-V
    "82-net-auto-link-local.hwdb" # which links get IPv4 link-local addresses
    "20-pci-classes.hwdb" # PCI class names
    "20-pci-vendor-model.hwdb" # PCI vendor and device names
    "20-usb-classes.hwdb" # USB class names
    "20-usb-vendor-model.hwdb" # USB vendor and product names
  ];
in
{
  hwdbUsrPath = usrPath;
  hwdbFiles = files;

  hwdb =
    {
      buildSystem,
      tool,
      systemd,
    }:
    common.nuDerivation {
      name = "golconda-hwdb";
      inherit buildSystem;
      module = "hwdb";
      tools = [ tool ];
      attrs = {
        sources = "${systemd}/lib/udev/hwdb.d";
        inherit files;
      };
    };

  hwdbFragment =
    { hwdb }:
    {
      name = "/image/hwdb";
      packages = [ hwdb ];
      links.${usrPath} = {
        target = "${hwdb}/hwdb.bin";
        kind = "explicit";
      };
    };
}
