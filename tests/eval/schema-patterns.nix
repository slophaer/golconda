# Checks of the schema patterns against their typedefs: each sample is accepted by both or refused by both.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  a,
  check,
  f,
  fr,
  s,
  schemaLib,
  v,
  versionAccepted,
  ...
}:
let
  inherit (builtins)
    all
    concatMap
    elemAt
    filter
    genList
    length
    match
    stringLength
    substring
    ;
in
[
  # A schema pattern and its typedef are one grammar: each sample is accepted by both
  # or refused by both. The pattern is read as builtins.match reads it, anchors off.
  (check "schema: every pattern accepts exactly what its type accepts" (
    let
      reg = schemaLib.typeRegistry;
      grammar = import ../../modules/lib/grammar.nix;
      inherit (import ../../modules/lib/path.nix) hasControl;
      whole = p: substring 1 (stringLength p - 2) p;
      # `not` with the control-character pattern refuses a value with one
      schemaAccepts =
        s: x:
        match (whole s.pattern) x != null
        && !((s.not.pattern or null) == grammar.controlSchema && hasControl x);
      sysOpts = (f.modules { }).modules.system.options;
      component = [
        "a"
        "foo-1.2_x"
        ".a"
        "..a"
        "..."
        "."
        ".."
        ""
        "a/b"
        "a b"
        "a\nb"
      ];
      years = [
        "1969"
        "1970"
        "2000"
        "2024"
        "2025"
        "2100"
      ];
      two = n: if n < 10 then "0${toString n}" else toString n;
      versions =
        concatMap (y: concatMap (m: genList (d: "${y}${two m}${two d}.1") 33) (genList (m: m) 14)) years
        ++ map (r: "20261031.${r}") [
          "0"
          "00"
          "01"
          "9999"
          "10000"
          "85999"
          "86399"
          "86400"
          ""
        ]
        ++ [
          "2026103.1"
          "20261031"
          "x20261031.1"
        ];
      cases = [
        {
          s = reg.imageName;
          t = sysOpts.name.type.verify;
          xs = [
            "host"
            "my-host_2.1"
            "-a"
            ".a"
            "a/../b c"
            "hôte"
            ""
          ];
        }
        {
          s = reg.version;
          t = sysOpts.version.type.verify;
          xs = versions;
        }
        {
          s = reg.fileMode;
          t = fr.mode.verify;
          xs = [
            "0644"
            "644"
            "0844"
            "00644"
          ];
        }
        {
          s = (elemAt reg.file.anyOf 1).properties.mode;
          t = fr.mode.verify;
          xs = [
            "0755"
            "755"
          ];
        }
        {
          s = reg.unitName;
          t = fr.unitName.verify;
          xs = [
            "sshd.service"
            "getty@.service"
            "a:b.slice"
            "a\\b.service"
            "a.conf"
            "a b.service"
            ".service"
          ];
        }
        {
          s = reg.serviceName;
          t = s.name.verify;
          xs = [
            "sshd"
            "a:b.c-d"
            "a\\b"
            "a@b"
            "a b"
            ""
          ];
        }
        {
          s = reg.targetName;
          t = fr.targetName.verify;
          xs = [
            "multi-user.target"
            "a\\b.target"
            "a.service"
            ".target"
          ];
        }
        {
          s = reg.varName;
          t = v.varName.verify;
          xs = component;
        }
        {
          s = reg.word;
          t = v.word.verify;
          xs = component;
        }
        {
          s = reg.stateDirectory;
          t = s.stateDirectory.verify;
          xs = component;
        }
        {
          s = reg.credentialId;
          t = s.credentialId.verify;
          xs = [
            "sshd-hostkey.key"
            "a@b:c"
            "a/b"
            "a b"
          ];
        }
        {
          s = reg.credentialPrefix;
          t =
            x:
            a.credentialRef.verify {
              credential = "c";
              prefix = x;
            };
          xs = [
            ""
            "-o"
            "HostCertificate="
            "a b"
            "a;b"
          ];
        }
        {
          s = reg.programName;
          t = a.programName.verify;
          xs = [
            "sshd"
            "g++"
            "a/b"
            ""
          ];
        }
        {
          s = reg.env.propertyNames;
          t = a.envName.verify;
          xs = [
            "HOME"
            "_A1"
            "1A"
            "A-B"
          ];
        }
        {
          s = reg.appFiles.propertyNames;
          t = x: a.files.verify { ${x} = "text"; };
          xs = [
            "principals/root"
            "a"
            ".a"
            "a b"
            "a/.../b"
            "../x"
            "a/./b"
            "/a"
            "a//b"
            "a/"
            ""
            "a\nb"
          ];
        }
        {
          s = reg.links.propertyNames;
          t =
            x:
            fr.links.verify {
              ${x} = {
                target = "t";
                kind = "explicit";
              };
            };
          xs = [
            "/usr/lib/x"
            "/usr/.x"
            "/usr/a b"
            "/usr/bin/../lib/x"
            "/usr/../etc/x"
            "/usr//x"
            "/usr/x/"
            "/usr/./x"
            "/usr"
            "/usr/"
            "/etc/x"
            "/usr/a\nb"
          ];
        }
      ];
      disagree = concatMap (c: filter (x: schemaAccepts c.s x != (c.t x == null)) c.xs) cases;
    in
    if disagree == [ ] then
      true
    else
      throw "schema and type disagree on ${toString (length disagree)} samples, such as: ${
        toString (genList (elemAt disagree) (if length disagree < 12 then length disagree else 12))
      }"
  ))
  # POSIX reads a backslash in a bracket expression as itself and ECMA-262 as an escape,
  # so `[:_.\-]` let a backslash into a name that the exported schema refused
  (check "a unit, service or target name has no backslash" (
    fr.unitName.verify "a\\b.service" != null
    && s.name.verify "a\\b" != null
    && fr.targetName.verify "a\\b.target" != null
  ))
  # lib/version.nix refuses a date that does not exist; so must the schema and the type
  (check "version: a refused version is refused by lib/version.nix, the schema and /system" (
    let
      versionLib = import ../../lib/version.nix { };
      pattern = schemaLib.typeRegistry.version.pattern;
      schemaAccepts = x: match (substring 1 (stringLength pattern - 2) pattern) x != null;
      refused = [
        "20260231.1"
        "20250229.1"
        "21000229.1"
        "19691231.1"
        "20261031.01"
        "20261031.86400"
      ];
      accepted = [
        "20240229.1"
        "20000229.0"
        "20261031.86399"
      ];
    in
    all (x: !versionLib.check x && !schemaAccepts x && !versionAccepted x) refused
    && all (x: versionLib.check x && schemaAccepts x && versionAccepted x) accepted
  ))
]
