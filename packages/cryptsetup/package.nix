# cryptsetup: disk encryption setup (LUKS, dm-crypt, dm-verity, dm-integrity)
#
# Provides cryptsetup, veritysetup, and integritysetup commands.
# Uses OpenSSL as the crypto backend and links against libdevmapper.
{
  package,
  pkgs,
}:
package {
  name = "cryptsetup";
  uses = [ "autotools" ];
  dependencies = [
    pkgs.openssl
    pkgs.lvm2 # libdevmapper
    pkgs.json-c
    pkgs.popt
    pkgs.util-linux # libblkid, libuuid
  ];
  autotools.flags = [
    "--with-crypto_backend=openssl"
    "--disable-ssh-token" # no libssh
    "--disable-external-tokens" # avoid hardcoded plugin path
    "--disable-asciidoc" # no man page generation
    "--disable-nls"
  ];
  # Tests need root and devices
  tests.run = false;
  bin = [
    "cryptsetup"
    "veritysetup"
    "integritysetup"
  ];
  platforms.os = [ "linux" ];
}
