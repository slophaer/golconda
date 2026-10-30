# The platform model: one place that turns a Nix double into every spelling
# the toolchain, systemd, UEFI and the kernel want. repkgs' `platform` reads
# the double; everything else reads the record. Add a platform here and only here.
let
  table = {
    x86_64-linux = {
      cpu = "x86_64";
      os = "linux";
      systemd = "x86-64"; # systemd-repart --architecture, DPS partition type names
      uefi = "x64"; # BOOTX64.EFI, systemd-bootx64.efi
      kernel = "x86_64"; # ARCH= for the kernel build
      march = "x86-64-v3"; # repkgs CPU baseline, injected by jig
    };
    aarch64-linux = {
      cpu = "aarch64";
      os = "linux";
      systemd = "arm64";
      uefi = "aa64";
      kernel = "arm64";
      march = "armv8.2-a+lse";
    };
  };
in
rec {
  supported = builtins.attrNames table;

  # elaborate "x86_64-linux" -> { double; cpu; os; systemd; uefi; kernel; march; }
  elaborate =
    double:
    if table ? ${double} then
      table.${double} // { inherit double; }
    else
      throw "golconda: unsupported platform '${double}'; supported: ${toString supported}";
}
