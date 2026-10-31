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
      text = concatStringsSep "\n" (
        [
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
        )
        ++ [
          ""
          "[Service]"
          "Type=oneshot"
          "RemainAfterExit=yes"
          "RuntimeDirectory=golconda-var/${v.name}"
          "RuntimeDirectoryMode=0700"
          "StateDirectory=golconda/vars/${v.name}"
          "StateDirectoryMode=0700"
          "ExecStart=/usr/lib/golconda/golconda-var-run ${v.name} \"${concatStringsSep " " v.secrets}\" \"${concatStringsSep " " publics}\""
          ""
        ]
      );
    in
    {
      units.${unitName v.name} = text;
      files = {
        "/usr/lib/golconda/vars.d/${v.name}.json" = toJSON {
          inherit (v) name secrets;
          inherit publics after;
          credentials = map (credentialId v.name) v.secrets;
        };
        "/usr/lib/golconda/vars.d/${v.name}.sh" = v.script + "\n";
      };
      packages = v.packages or [ ];
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
