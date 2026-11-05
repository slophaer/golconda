# The hwdb.d files a server reads, compiled into hwdb.bin (package.nix). The full database is
# 13.9 MB; this selection is 8.0 MB: the PCI and USB vendor, model and class names
# (ID_VENDOR_FROM_DATABASE, ID_MODEL_FROM_DATABASE: what udevadm info, networkctl and lsusb-style
# tools show for a device) and the few entries a server acts on. Left out: MAC address vendors
# (20-OUI, 3 MB of names for nothing a server reads) and the desktop input quirks (keyboards,
# mice, touchpads, sensors, cameras). tests/eval/hwdb.nix checks the selection.
[
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
]
