# Checks of /system: the version format (YYYYMMDD.N) and updateSource, which renders sysupdate.d.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  composeWith,
  hasInfix,
  hasPrefix,
  hasSuffix,
  versionAccepted,
  ...
}:
let
  inherit (builtins) all any;
in
[
  (check "updateSource: direct module calls validate transfer paths" (
    let
      accepts =
        updateSource:
        (builtins.tryEval (
          builtins.deepSeq
            (composeWith {
              "/system" = {
                name = "t";
                version = "20261031.1";
                inherit updateSource;
              };
            }).files
            true
        )).success;
    in
    all accepts [
      null
      "https://example.com/releases/"
      "/srv/releases"
    ]
    && !(any accepts [
      "relative/path"
      "https://example.com/\n[Evil]"
      "/srv/has space"
      42
    ])
  ))
  # 7. Version format: YYYYMMDD.N
  (check "version format: YYYYMMDD.N accepted" (
    all versionAccepted [
      "20261031.1"
      "20260101.0"
      "20301231.99"
    ]
  ))
  (check "version format: invalid versions rejected" (
    let
      invalidVersions = [
        "0"
        "2026.10.31"
        "2026-10-31.1"
        "20261031"
        "v1.0.0"
        # a real calendar date, not only eight digits: the epoch must not alias another day
        "20260231.1"
        "20250229.1"
        "20260431.1"
        "20261301.1"
        "20260001.1"
        "20261032.1"
        "20261000.1"
        # the revision is a second inside the day, not a free counter
        "20261031.86400"
        "20261031.999999999999"
        "19691231.1"
      ];
    in
    !(any versionAccepted invalidVersions)
  ))
  (check "version format: a revision with a leading zero is refused (two spellings, one epoch)" (
    let
      versionLib = import ../../lib/version.nix { };
    in
    !(any versionAccepted [
      "20261031.01"
      "20261031.00"
      "20261031.0086399"
    ])
    && hasInfix "leading zero" (versionLib.error "20261031.01")
    && all versionAccepted [
      "20261031.0"
      "20261031.10"
    ]
  ))
  (check "version format: leap day and the last second of a day are accepted" (
    all versionAccepted [
      "20240229.0"
      "20000229.1"
      "20261031.86399"
      "20261101.0"
    ]
  ))
  # 7b. /system.updateSource renders sysupdate.d
  (check "system: updateSource renders /usr/lib/sysupdate.d/*.transfer with Path=" (
    let
      result = composeWith {
        "/system" = {
          name = "t";
          version = "20261031.1";
          fragments = [ ];
          updateSource = "https://updates.example/t/";
        };
      };
      usr = result.files."/usr/lib/sysupdate.d/10-usr.transfer".text;
      names = builtins.attrNames result.files;
    in
    hasInfix "[Source]" usr
    && hasInfix "Path=https://updates.example/t/" usr
    && hasInfix "MatchPattern=t_@v.usr.@u.raw" usr
    && hasInfix "ProtectVersion=%A" usr
    && hasInfix "Verify=yes" usr
    && result.files ? "/usr/lib/sysupdate.d/40-uki.transfer"
    # systemd 257+ wants the .transfer suffix and warns on .conf
    && !(builtins.any (n: hasPrefix "/usr/lib/sysupdate.d/" n && hasSuffix ".conf" n) names)
  ))
  (check "system: updateSource enables the update timer with a static link" (
    let
      result = composeWith {
        "/system" = {
          name = "t";
          version = "20261031.1";
          fragments = [ ];
          updateSource = "https://updates.example/t/";
        };
      };
    in
    # systemd 262 renamed systemd-sysupdate.timer to systemd-sysupdate-update.timer; the old
    # name is an alias of it
    result.links."/usr/lib/systemd/system/timers.target.wants/systemd-sysupdate-update.timer" == {
      target = "../systemd-sysupdate-update.timer";
      kind = "explicit";
    }
  ))
  (check "system: no updateSource, no sysupdate.d and no update timer" (
    let
      result = composeWith { };
    in
    !(builtins.any (n: hasPrefix "/usr/lib/sysupdate.d/" n) (builtins.attrNames result.files))
    && !(result.links ? "/usr/lib/systemd/system/timers.target.wants/systemd-sysupdate-update.timer")
  ))
]
