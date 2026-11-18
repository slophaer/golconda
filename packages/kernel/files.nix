# The files the kernel build copies into its tree before configure (kbuild.nu copy-files), by
# path in the tree: the IPE boot policy at the path golconda.config names. nix/packages.nix adds
# the verity certificate to these.
{
  "security/ipe/golconda-boot-policy" = "${builtins.path {
    path = ./ipe-boot-policy;
    name = "ipe-boot-policy";
  }}";
}
