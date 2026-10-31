# Vars: values generated on the machine, once, that never enter the image.
# A var is a fragment: a oneshot unit `golconda-var-<name>.service` runs the
# generator script on first boot, seals each secret file to the TPM as the
# credential `<name>.<file>` and keeps public files in
# /var/lib/golconda/vars/<name>/pub. The image carries only the declaration
# (the manifest in /usr/lib/golconda/vars.d/). Report:
# ~/spikes/research-vars/REPORT.md section 3.1.
#
#   let v = import ../../lib/var.nix { inherit types; };
#   in v.render { name = "foo-key"; secrets = [ "key" ]; publics = [ "key.pub" ];
#                 script = "foo-keygen -o key"; packages = [ foo ]; }
#
# A consumer service names the credential, never a path:
#   credentials.key = v.credentialId "foo-key" "key";    # LoadCredentialEncrypted=key:foo-key.key
#   after = [ (v.unitName "foo-key") ]; wants = [ (v.unitName "foo-key") ];
#
# The runner /usr/lib/golconda/golconda-var-run (modules/lib/golconda-var-run)
# is one file for all vars, so the /vars module installs it: add `/vars` to
# the fragments once (mode 0755). The runner needs /bin/sh, coreutils and
# systemd-creds in the image.
{ types }:
let
  inherit (types)
    derivation
    listOf
    optionalAttr
    string
    struct
    typedef'
    ;
  inherit (builtins)
    concatStringsSep
    isString
    match
    toJSON
    ;

  # a var name or a file name: one path component, shell-safe
  word = typedef' "word" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[A-Za-z0-9_.-]+" v == null then
      "'${v}' must be one path component of letters, digits, _ . -"
    else
      null
  );

  # A target name: what systemd accepts for WantedBy= / RequiredBy=.
  targetName = typedef' "targetName" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[A-Za-z0-9:_.\\-]+\\.target" v == null then
      "'${v}' is not a valid target name (must end with .target)"
    else
      null
  );

  var = struct "var" {
    name = word;
    # files the script writes that are sealed as credentials <name>.<file>
    secrets = listOf word;
    # files kept readable in /var/lib/golconda/vars/<name>/pub; default [ ]
    publics = optionalAttr (listOf word);
    # names of vars that must run first; their pub/ directories are readable; default [ ]
    after = optionalAttr (listOf word);
    # POSIX sh, run in the (empty) runtime directory with the image's tools on PATH
    script = string;
    # tools the script needs; default [ ]
    packages = optionalAttr (listOf derivation);
    # targets that pull in this unit; default [ "multi-user.target" ]
    # consumer services add After=<var>.service to order themselves after the var
    wantedBy = optionalAttr (listOf targetName);
  };

  unitName = name: "golconda-var-${name}.service";
  credentialId = name: file: "${name}.${file}";
  stateDir = name: "/var/lib/golconda/vars/${name}";

  build =
    v:
    let
      after = v.after or [ ];
      publics = v.publics or [ ];
      deps = concatStringsSep " " (map unitName after);
      wantedByTargets = v.wantedBy or [ "multi-user.target" ];

      unitSection = [
        "[Unit]"
        "Description=Generate var ${v.name}"
        "ConditionPathExists=!${stateDir v.name}/done"
      ]
      ++ (
        if after == [ ] then
          [ ]
        else
          [
            "After=${deps}"
            "Requires=${deps}"
          ]
      );

      serviceSection = [
        "[Service]"
        "Type=oneshot"
        "RemainAfterExit=yes"
        "RuntimeDirectory=golconda-var/${v.name}"
        "RuntimeDirectoryMode=0700"
        "StateDirectory=golconda/vars/${v.name}"
        "StateDirectoryMode=0700"
        "ExecStart=/usr/lib/golconda/golconda-var-run ${v.name} \"${concatStringsSep " " v.secrets}\" \"${concatStringsSep " " publics}\""
      ];

      installSection = [
        "[Install]"
      ]
      ++ map (t: "WantedBy=${t}") wantedByTargets;

      text = concatStringsSep "\n" (unitSection ++ [ "" ] ++ serviceSection ++ [ "" ] ++ installSection);

      # Static .wants symlinks: /usr/lib/systemd/system/<target>.wants/<unit> -> ../<unit>
      unit = unitName v.name;
      wantsLinks = map (t: {
        path = "/usr/lib/systemd/system/${t}.wants/${unit}";
        target = "../${unit}";
      }) wantedByTargets;
    in
    {
      units.${unitName v.name} = text + "\n";
      files = {
        "/usr/lib/golconda/vars.d/${v.name}.json" = toJSON {
          inherit (v) name secrets;
          inherit publics after;
          credentials = map (credentialId v.name) v.secrets;
        };
        "/usr/lib/golconda/vars.d/${v.name}.sh" = v.script + "\n";
      };
      packages = v.packages or [ ];
      links = wantsLinks;
    };

  render = v: var.check v (build v);
in
{
  inherit
    var
    word
    render
    unitName
    credentialId
    stateDir
    ;
}
