# Vars: values the image names but never contains. Two classes:
#
#   - local: generated on the machine at first boot (ssh host keys, wireguard
#     keys). The generator runs in a oneshot unit, seals secrets with
#     systemd-creds, and exports only public files.
#   - admin: kept age-encrypted on the deploy host, pushed over ssh, sealed on
#     the machine. The image carries only the manifest entry (class "admin").
#
# The manifest is /usr/lib/golconda/vars.d/<name>.json.
#
#   let v = import ../../lib/var.nix { inherit types; };
#   in v.render { name = "foo-key"; secrets = [ "key" ]; publics = [ "key.pub" ];
#                 script = "foo-keygen -o key"; packages = [ foo ]; }
#
# A consumer service names the credential, never a path:
#   credentials.key = v.credentialId "foo-key" "key";    # LoadCredentialEncrypted=foo-key.key, argv %d/foo-key.key
#   after = [ (v.unitName "foo-key") ]; wants = [ (v.unitName "foo-key") ];
#
# An admin-supplied var (`admin`) is the second class (docs/design/trust.md):
# the value is kept age-encrypted on the deploy host, pushed over ssh and
# sealed by the machine's own systemd-creds into /etc/credstore.encrypted,
# so the image carries only its manifest entry, class "admin", and no unit.
# The deploy tool reads the manifest from the image. The credential id is
# the same `<name>.<file>`, so a consumer does not know the class:
#   v.admin { name = "foo-cert"; files = [ "cert" ]; }
#   credentials.cert = v.credentialId "foo-cert" "cert";  # LoadCredentialEncrypted=foo-cert.cert
#
# The runner /usr/lib/golconda/golconda-var-run (modules/vars/golconda-var-run)
# is one file for all vars, so the /vars module installs it (mode 0755).
# /vars and /factory are built-in components (lib/components.nix): every system has
# them. The runner needs /bin/sh, coreutils and systemd-creds in the image.
{ types }:
let
  inherit (import ./fragment.nix { inherit types; }) targetName;
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
    toJSON
    ;

  # Filenames keep dots; var names reserve them for the credential separator.
  word = typedef' "word" (import ./path.nix).componentError;
  varName = typedef' "varName" (
    v:
    if !builtins.isString v then
      "Expected a string"
    else if builtins.match (import ./grammar.nix).varName v == null then
      "'${v}' is not a var name: use letters, digits, _ and - (dots separate credential filenames)"
    else
      null
  );

  var = struct "var" {
    name = varName;
    # files the script writes that are sealed as credentials <name>.<file>
    secrets = listOf word;
    # files kept readable in /var/lib/golconda/vars/<name>/pub; default [ ]
    publics = optionalAttr (listOf word);
    # names of vars that must run first; their pub/ directories are readable; default [ ]
    after = optionalAttr (listOf varName);
    # POSIX sh, run in the (empty) runtime directory with the image's tools on PATH
    script = string;
    # tools the script needs; default [ ]
    packages = optionalAttr (listOf derivation);
    # targets that pull in this unit; default [ "multi-user.target" ]
    # consumer services add After=<var>.service to order themselves after the var
    wantedBy = optionalAttr (listOf targetName);
  };

  # An admin-supplied var: the files the deploy host pushes, each sealed as
  # the credential <name>.<file>.
  # Nothing else: a script or a package would be the local class.
  adminVar =
    (struct "adminVar" {
      name = varName;
      files = listOf word;
    }).override
      { unknown = false; };

  unitName = name: "golconda-var-${name}.service";
  credentialId = name: file: "${name}.${file}";
  stateDir = name: "/var/lib/golconda/vars/${name}";
  manifestPath = name: "/usr/lib/golconda/vars.d/${name}.json";

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
      wantsLinks = builtins.listToAttrs (
        map (t: {
          name = "/usr/lib/systemd/system/${t}.wants/${unit}";
          value = {
            target = "../${unit}";
            kind = "explicit";
          };
        }) wantedByTargets
      );
    in
    {
      units.${unitName v.name} = text + "\n";
      files = {
        ${manifestPath v.name} = toJSON {
          inherit (v) name secrets;
          inherit publics after;
          class = "local";
          credentials = map (credentialId v.name) v.secrets;
        };
        "/usr/lib/golconda/vars.d/${v.name}.sh" = v.script + "\n";
      };
      packages = v.packages or [ ];
      links = wantsLinks;
    };

  render = v: var.check v (build v);

  # adminVar -> fragment: the manifest entry only. Nothing runs on the
  # machine; a consumer loads the credential by id and the unit fails to
  # start until the deploy host has pushed it.
  admin =
    v:
    adminVar.check v {
      files.${manifestPath v.name} = toJSON {
        inherit (v) name files;
        class = "admin";
        credentials = map (credentialId v.name) v.files;
      };
    };
in
{
  inherit
    var
    adminVar
    word
    varName
    render
    admin
    unitName
    credentialId
    stateDir
    ;
}
