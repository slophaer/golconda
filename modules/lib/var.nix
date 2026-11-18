# Vars: values the image names but never contains (docs/features/vars.md). A local var is
# generated on the machine at first boot; an admin var is kept age-encrypted on the deploy host,
# pushed over ssh and sealed by the machine. The manifest is /usr/lib/golconda/vars.d/<name>.json.
#   render var      a fragment with the unit, the manifest and the script
#   admin adminVar  a fragment with the manifest entry and `<name>.admin` only, and no unit
#   unitName, credentialId, stateDir   "golconda-var-<name>.service", "<name>.<file>" (both
#                   classes), "/var/lib/golconda/vars/<name>"
# A consumer names the credential, never a path: `credentials.key = v.credentialId "foo-key" "key"`.
# The runner modules/vars/golconda-var-run serves all vars; it needs /bin/sh, coreutils, grep and
# systemd-creds in the image.
{ types }:
let
  fragmentTypes = import ./fragment.nix { inherit types; };
  inherit (fragmentTypes) targetName;
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

  var =
    (struct "var" {
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
    }).override
      { unknown = false; };

  # An admin-supplied var: the files the deploy host pushes, each sealed as
  # the credential <name>.<file>, and the units that load them: the deploy tool
  # restarts those after a push, so a new value takes effect (default [ ]).
  # Nothing else: a script or a package would be the local class.
  adminVar =
    (struct "adminVar" {
      name = varName;
      files = listOf word;
      consumers = optionalAttr (listOf fragmentTypes.unitName);
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
        consumers = v.consumers or [ ];
      };
      # the files a push may seal, one per line: what golconda-var-run --admin compares
      files."/usr/lib/golconda/vars.d/${v.name}.admin" = concatStringsSep "" (map (f: "${f}\n") v.files);
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
