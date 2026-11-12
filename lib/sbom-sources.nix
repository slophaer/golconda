# lib/sbom-sources.nix: the packages Golconda compiles from another package's source, and where
# in it. They have no sources.toml (no second pin to keep in step), so the SBOM generator cannot
# give them a purl. `withSourcePurls` gives them the purl of that source package, at its pinned
# version, plus a purl subpath (https://github.com/package-url/purl-spec: `#` then the path
# inside the package, relative, `/`-separated, each segment percent-encoded):
#   hwdb           pkg:github/systemd/systemd@262.1#hwdb.d
#   gen-init-cpio  pkg:generic/linux@6.18.60#usr/gen_init_cpio.c
#   ca-bundle      pkg:github/certifi/python-certifi@2026.07.22#certifi/cacert.pem
# No cpe: the NVD names the project's product (systemd, linux_kernel), and neither package is
# that product; a systemd cpe on hwdb would report systemd's CVEs against a data file.
#
# A new entry is { <package> = { from = "<source package>"; subpath = "<path>"; }; }.
{
  hwdb = {
    from = "systemd";
    subpath = "hwdb.d";
  };
  gen-init-cpio = {
    from = "linux-kernel";
    subpath = "usr/gen_init_cpio.c";
  };
  ca-bundle = {
    from = "cacert";
    subpath = "certifi/cacert.pem";
  };
}
