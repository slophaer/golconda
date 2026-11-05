# Checks of the read-only /etc: the confext mkSystem builds from the image's own tmpfiles and
# sysusers lines, its place in /usr, the initrd's merge, the static links that replace the
# first-boot presets, the credential store on /var and overlayfs in the kernel.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  f,
  hasInfix,
  system,
  ...
}:
let
  inherit (builtins)
    any
    elem
    readFile
    ;

  sys = f.lib.mkSystem {
    config = {
      "/system" = {
        name = "t";
        version = "20261031.1";
      };
    };
    system = "x86_64-linux";
  };
  confext = sys.etcConfext;
  confextLink = "/usr/lib/confexts/golconda";
  linkPaths = tree: map (l: l.path) tree.links;
  initrdTree = (import ../../lib/image { }).initrdTree {
    imageId = "t";
    version = "20261031.1";
    inherit (sys) pkgs platform;
    buildSystem = "x86_64-linux";
  };
  credstore = "/var/lib/golconda/credstore.encrypted";
  runner = system.files."/usr/lib/golconda/golconda-var-run".text;
in
[
  (check "etc: the /usr tree links the confext at /usr/lib/confexts/golconda" (
    any (l: l.path == confextLink && l.target == confext.outPath) sys.usrTree.links
    && elem confext.outPath (map (p: p.outPath) sys.usrTree.roots)
  ))
  (check "etc: the confext runs the image's own tmpfiles and sysusers lines" (
    hasInfix "L /etc/pam.d/sshd - - - - /usr/share/factory/etc/pam.d/sshd" confext.tmpfiles
    && confext.sysusers == builtins.concatStringsSep "\n" sys.composed.sysusers + "\n"
    && confext.systemdTmpfiles == "${sys.pkgs.systemd}/lib/tmpfiles.d"
    && confext.systemdSysusers == "${sys.pkgs.systemd}/lib/sysusers.d"
  ))
  (check "etc: the confext names this image and its version" (
    confext.extensionRelease == "ID=t\nVERSION_ID=20261031.1\n"
  ))
  (check "etc: the initrd builds no confext of its own" (!elem confextLink (linkPaths initrdTree)))
  (check "etc: the initrd merges the confext before switch-root" (
    elem "/usr/lib/systemd/system/initrd.target.wants/systemd-confext-sysroot.service" (
      linkPaths initrdTree
    )
  ))
  (check "etc: network credentials are imported without first-boot presets" (
    sys.composed.links
      ? "/usr/lib/systemd/system/sysinit.target.wants/systemd-network-generator.service"
  ))
  (check "etc: sysusers runs only on a writable /etc (users come from the build)" (
    hasInfix "ConditionPathIsReadWrite=/etc" (
      sys.composed.files."/usr/lib/systemd/system/systemd-sysusers.service.d/golconda.conf".text or ""
    )
  ))
  (check "etc: the var runner seals into /var, not /etc" (
    hasInfix "credstore=${credstore}\n" runner && !hasInfix "/etc/credstore" runner
  ))
  (check "etc: the credential store on /var is made at boot, root only" (
    elem "d ${credstore} 0700 root root -" system.tmpfiles
  ))
  (check "etc: the machine id comes from the firmware UUID on bare metal too (a credential wins)" (
    hasInfix " systemd.machine_id=firmware " (import ../../image/uki.nix).cmdlineTemplate
  ))
  (check "etc: the initrd hides the writable confext directories before the merge" (
    let
      u = sys.composed.units;
      guard =
        where: unit:
        (
          hasInfix "Where=${where}\n" unit
          && hasInfix "Type=tmpfs\n" unit
          && hasInfix "Options=ro," unit
          && hasInfix "Before=systemd-confext-sysroot.service\n" unit
          && hasInfix "ConditionPathExists=/etc/initrd-release\n" unit
        );
      requires =
        n: sys.composed.links ? "/usr/lib/systemd/system/systemd-confext-sysroot.service.requires/${n}";
    in
    guard "/sysroot/var/lib/confexts" (u."sysroot-var-lib-confexts.mount" or "")
    && guard "/sysroot/run/confexts" (u."sysroot-run-confexts.mount" or "")
    && requires "sysroot-var-lib-confexts.mount"
    && requires "sysroot-run-confexts.mount"
  ))
  (check "etc: overlayfs is in the kernel (systemd-confext merges /etc with it)" (
    hasInfix "\nCONFIG_OVERLAY_FS=y\n" (readFile ../../packages/kernel/golconda.config)
  ))
]
