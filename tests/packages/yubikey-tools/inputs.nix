# the test tells the bundle's pcscd and tool apart from the dependencies' by their paths
pkgs: { inherit (pkgs) ccid yubico-piv-tool pcsc-lite; }
