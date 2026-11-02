# Checks of /vars: the admin var manifest, the runner script and the var unit.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  hasInfix,
  system,
  throws,
  v,
  ...
}:
let
  inherit (builtins) attrNames deepSeq tryEval;

  varUnit = system.units."golconda-var-sshd-hostkey.service";
in
[
  (check "var: runs once" (
    hasInfix "ConditionPathExists=!/var/lib/golconda/vars/sshd-hostkey/done" varUnit
  ))
  (check "var: runner arguments" (
    hasInfix "ExecStart=/usr/lib/golconda/golconda-var-run sshd-hostkey \"key\" \"key.pub\"" varUnit
  ))
  (check "var: manifest and script" (
    system.files ? "/usr/lib/golconda/vars.d/sshd-hostkey.json"
    && system.files ? "/usr/lib/golconda/vars.d/sshd-hostkey.sh"
  ))
  (check "vars: runner installed once" (system.files ? "/usr/lib/golconda/golconda-var-run"))
  (check "vars: runner is executable" (
    system.files."/usr/lib/golconda/golconda-var-run".mode == "0755"
  ))
  (check "var: an admin var is a manifest entry and nothing else" (
    let
      frag = v.admin {
        name = "root-password";
        files = [
          "hash"
          "salt"
        ];
      };
    in
    attrNames frag == [ "files" ]
    && attrNames frag.files == [ "/usr/lib/golconda/vars.d/root-password.json" ]
    &&
      builtins.fromJSON frag.files."/usr/lib/golconda/vars.d/root-password.json" == {
        name = "root-password";
        class = "admin";
        files = [
          "hash"
          "salt"
        ];
        credentials = [
          "root-password.hash"
          "root-password.salt"
        ];
      }
  ))
  (check "var: one credential id for both classes" (
    v.credentialId "sshd-hostkey" "key" == "sshd-hostkey.key"
    && v.credentialId "sshd-host-cert" "cert" == "sshd-host-cert.cert"
    &&
      (builtins.fromJSON system.files."/usr/lib/golconda/vars.d/sshd-hostkey.json".text).class == "local"
    &&
      (builtins.fromJSON system.files."/usr/lib/golconda/vars.d/sshd-hostkey.json".text).credentials
      == [ "sshd-hostkey.key" ]
  ))
  (check "var: admin var names and files are words, files are required" (
    !(tryEval (
      deepSeq (v.admin {
        name = "a b";
        files = [ "x" ];
      }) true
    )).success
    && !(tryEval (
      deepSeq (v.admin {
        name = "a";
        files = [ "../x" ];
      }) true
    )).success
    && !(tryEval (deepSeq (v.admin { name = "a"; }) true)).success
    && !(tryEval (
      deepSeq (v.admin {
        name = "a";
        files = [ "x" ];
        script = "";
      }) true
    )).success
  ))
  (check "var: names and dependencies reserve dots for credential ids" (
    throws (
      v.render {
        name = "foo.bar";
        secrets = [ "key" ];
        script = "";
      }
    )
    && !(tryEval (
      deepSeq (v.admin {
        name = "foo.bar";
        files = [ "key" ];
      }) true
    )).success
    && throws (
      v.render {
        name = "foo";
        secrets = [ "bar.key" ];
        after = [ "foo.bar" ];
        script = "";
      }
    )
  ))
  (check "var: filenames retain dots without ambiguous ownership" (
    let
      local = v.render {
        name = "foo";
        secrets = [ "bar.key" ];
        publics = [ "key.pub" ];
        script = "";
      };
      admin = v.admin {
        name = "foo";
        files = [ "bar.key" ];
      };
    in
    (builtins.fromJSON local.files."/usr/lib/golconda/vars.d/foo.json").credentials == [ "foo.bar.key" ]
    &&
      (builtins.fromJSON admin.files."/usr/lib/golconda/vars.d/foo.json").credentials == [ "foo.bar.key" ]
  ))
  (check "var file names are one component" (
    throws (
      v.render {
        name = "x";
        secrets = [ "../etc/shadow" ];
        script = "";
      }
    )
  ))
]
