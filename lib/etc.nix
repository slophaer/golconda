# lib/etc.nix: the image's /etc as a directory confext, so /etc is read-only and verified.
#
# etcConfext { composed; pkgs; buildSystem; } → a derivation whose output is `etc/`: what a
# first boot of this system writes to /etc, made at build time by systemd-tmpfiles
# (--prefix=/etc) and systemd-sysusers over the image's own configuration (lib/image/etc.nu).
# mkSystem links it at /usr/lib/confexts/golconda; the initrd's systemd-confext-sysroot.service
# merges it onto /sysroot/etc (read-only, overlayfs, no upper layer) before switch-root.
#
# Its etc/extension-release.d/extension-release.golconda names this image and version (ID=,
# VERSION_ID=), so the confext merges only into the /usr it came with.
#
# What a read-only /etc changes (docs/design/layout.md):
# - /etc/machine-id is empty: PID 1 takes the id from the VM's SMBIOS UUID, the
#   system.machine_id credential or at random (machine-id(5)), and mounts it over the file.
#   An empty file is not a first boot, so first-boot presets do not run.
# - passwd, group and shadow come from sysusers at build time; at boot sysusers finds every
#   user and writes nothing.
# - The store makes every file 0444 and every directory 0555, so /etc/shadow is
#   world-readable. It holds no password: Golconda has none (docs/design/trust.md).
# - tmpfiles lines for /etc ran at build time; etc/tmpfiles.d/ drops them for the boot, and a
#   credential such as network.hosts (an `f^ /etc/hosts` line) has no effect.
# - An administrator changes nothing in /etc: a change is a new image.
_:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    listToAttrs
    stringLength
    substring
    ;
  common = import ./image/common.nix { };
  factoryPrefix = "/usr/share/factory/etc/";
  n = stringLength factoryPrefix;
in
{
  etcConfext =
    {
      composed,
      pkgs,
      buildSystem,
    }:
    let
      lines = l: concatStringsSep "\n" l + "\n";
      factoryPaths = filter (p: substring 0 n p == factoryPrefix) (attrNames composed.files);
    in
    common.nuDerivation {
      name = "${composed.name}-${composed.version}-etc";
      inherit buildSystem;
      module = "etc";
      tools = [ pkgs.systemd ]; # systemd-tmpfiles, systemd-sysusers; cp, ln, readlink: the seed
      attrs = {
        tmpfiles = lines composed.tmpfiles;
        sysusers = lines composed.sysusers;
        systemdTmpfiles = "${pkgs.systemd}/lib/tmpfiles.d";
        systemdSysusers = "${pkgs.systemd}/lib/sysusers.d";
        factory = listToAttrs (
          map (p: {
            name = substring n (stringLength p - n) p;
            value = composed.files.${p}.text;
          }) factoryPaths
        );
        extensionRelease = "ID=${composed.name}\nVERSION_ID=${composed.version}\n";
      };
    };
}
