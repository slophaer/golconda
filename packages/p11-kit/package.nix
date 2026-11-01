# PKCS#11 module loader and the `trust` tool that derives CA bundles from a directory of anchors
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "p11-kit";
  uses = [ "meson" ];
  # bin/trust and libexec/p11-kit are found next to the running executable (upstream compiles
  # them in as <prefix>/...). The ambient paths below are where p11-kit looks, the patch installs
  # its own modules and module config under the package (lib/pkcs11, share/p11-kit/modules) for
  # the composer to link there
  patches = [ ./relocatable.patch ];
  meson.defs = {
    sysconfdir = "/etc";
    libffi = "enabled";
    trust_module = "enabled";
    # ambient paths: the one CA store (Golconda docs/design/trust.md), modules and their config.
    # trust_paths is the token root: anchors are read from /etc/ssl/anchors/*.pem and distrust
    # entries from /etc/ssl/blocklist
    trust_paths = "/etc/ssl";
    module_path = "/usr/lib/pkcs11";
    system_config = "/etc/pkcs11";
    module_config = "/usr/share/p11-kit/modules"; # where other packages register their modules
    systemd = "disabled"; # systemd dlopens p11-kit, not the other way round
    bash_completion = "disabled";
    zsh_completion = "disabled";
    nls = false;
    man = false;
    gtk_doc = false;
    test = false;
  };
  buildDependencies = [ buildPkgs.libtasn1 ]; # asn1Parser runs during the build
  dependencies = [
    pkgs.libtasn1
    pkgs.libffi
  ];
  bin = [
    "p11-kit"
    "trust"
  ];
  platforms.os = [ "linux" ];
}
