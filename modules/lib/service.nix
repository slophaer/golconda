# The service type and its systemd renderer, the one renderer. A service is
# an `app` (app.nix) plus what only a unit has: credentials, state, user,
# sandbox, ordering. `render service` returns a fragment (fragment.nix):
# ExecStart=/usr/bin/<program> <argv...>, where a credential reference in
# argv is %d/<name> and the app's files are written to /usr/lib/<name>/<file>
# (`filesDir name`). No enable flag: a service in `fragments` is on. Two
# instances are two names; the composer refuses a duplicate unit. Report:
# ~/spikes/research-services/REPORT.md section 3.
#
#   let s = import ../../lib/service.nix { inherit types; };
#   in s.render { name = "foo"; app = { package = pkg; argv = [ "-f" "${s.filesDir "foo"}/foo.conf" ];
#                 files."foo.conf" = "..."; }; user = "dynamic"; sandbox = "strict"; }
{ types }:
let
  appLib = import ./app.nix { inherit types; };
  inherit (import ./var.nix { inherit types; }) word;
  inherit (appLib)
    app
    exe
    isCredentialRef
    ;
  inherit (types)
    attrsOf
    enum
    listOf
    optionalAttr
    string
    struct
    typedef'
    ;
  inherit (builtins)
    attrNames
    concatLists
    concatStringsSep
    elemAt
    filter
    isString
    match
    replaceStrings
    sort
    split
    ;

  # A unit name stem: what systemd accepts before ".service".
  name = typedef' "serviceName" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[A-Za-z0-9:_.\\-]+" v == null then
      "'${v}' is not a valid unit name stem (letters, digits, : _ . -)"
    else
      null
  );

  # Who runs the service: "dynamic" (DynamicUser=), "root", or a sysusers
  # `u` line, which becomes User= and a sysusers entry.
  isSysusersLine = v: match "u!? +[a-z_][a-z0-9_-]* .*" v != null;
  user = typedef' "serviceUser" (
    v:
    if !isString v then
      "Expected a string"
    else if v == "dynamic" || v == "root" || isSysusersLine v then
      null
    else
      "'${v}' is neither \"dynamic\", \"root\" nor a sysusers line like 'u foo - \"Foo daemon\"'"
  );
  sysusersName = line: elemAt (filter isString (split " +" line)) 1;

  # Three fixed hardening sets. Golconda's own, modelled on the portable
  # service profiles of the same names; not a free-form systemd.exec surface.
  sandbox = enum "sandbox" [
    "strict"
    "default"
    "trusted"
  ];
  sandboxLines = {
    # The program sees the system: login services (sshd), container managers.
    trusted = [ ];
    default = [
      "NoNewPrivileges=yes"
      "PrivateTmp=yes"
      "ProtectSystem=strict"
      "ProtectHome=yes"
      "ProtectControlGroups=yes"
      "ProtectKernelModules=yes"
      "ProtectKernelTunables=yes"
      "ProtectKernelLogs=yes"
      "RestrictRealtime=yes"
      "RestrictNamespaces=yes"
      "RestrictSUIDSGID=yes"
      "LockPersonality=yes"
      "RemoveIPC=yes"
    ];
    strict = sandboxLines.default ++ [
      "CapabilityBoundingSet="
      "PrivateDevices=yes"
      "PrivateUsers=yes"
      "ProtectClock=yes"
      "ProtectHostname=yes"
      "ProtectProc=invisible"
      "ProcSubset=pid"
      "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"
      "MemoryDenyWriteExecute=yes"
      "SystemCallArchitectures=native"
      "SystemCallFilter=@system-service"
      "SystemCallFilter=~@privileged @resources"
      "SystemCallErrorNumber=EPERM"
    ];
  };

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

  # How the unit's processes are killed on stop (KillMode=). `process` is for
  # a daemon whose children must outlive it, such as sshd's sessions.
  killMode = enum "killMode" [
    "control-group"
    "process"
    "mixed"
  ];

  # Which manager runs the unit: the system manager (PID 1, the unit under
  # /usr/lib/systemd/system) or every user's own (`systemd --user`, the unit
  # under /usr/lib/systemd/user).
  scope = enum "serviceScope" [
    "system"
    "user"
  ];
  isUser = svc: (svc.scope or "system") == "user";

  service =
    (struct "service" {
      inherit
        name
        app
        sandbox
        ;
      # default "system"
      scope = optionalAttr scope;
      # required for a system service; refused for a user one, which runs as
      # the user whose manager starts it
      user = optionalAttr user;
      # credential name -> credstore id: LoadCredentialEncrypted=name:id; default { }.
      # System scope only: Golconda seals credentials for the system manager.
      # app.argv names a credential as { credential = "n"; prefix ? ""; }.
      credentials = optionalAttr (attrsOf string);
      # StateDirectory= entries under /var/lib; default [ ]
      state = optionalAttr (listOf string);
      # RuntimeDirectory= under /run, one component; default none
      runtimeDirectory = optionalAttr word;
      # KillMode=; default control-group (systemd's own)
      killMode = optionalAttr killMode;
      # unit ordering; default [ ]
      after = optionalAttr (listOf string);
      wants = optionalAttr (listOf string);
      # targets that pull in this unit; default [ "multi-user.target" ], for a
      # user service [ "default.target" ]
      # generates static .wants symlinks; [Install] section kept for admin overrides
      wantedBy = optionalAttr (listOf targetName);
    }).override
      {
        # no unknown field: a stale or misspelt one is an error
        unknown = false;
        verify =
          svc:
          if isUser svc && svc ? user then
            "a user service runs as the user whose manager starts it: `user` is refused (User= and DynamicUser= are system-manager settings)"
          else if !isUser svc && !(svc ? user) then
            "a system service names its user: \"dynamic\", \"root\" or a sysusers line"
          else if isUser svc && (svc.credentials or { }) != { } then
            "a user service cannot load a Golconda credential: credentials are sealed for the system manager in /etc/credstore.encrypted, which the per-user manager does not search (systemd.exec(5), Credentials); make it a system service"
          else
            null;
      };

  # systemd command-line text: % and $ are specifiers and variables, so they
  # double; an argument with whitespace or quotes is double-quoted.
  escape = s: replaceStrings [ "%" "$" ] [ "%%" "$$" ] s;
  quote =
    s:
    if s != "" && match "[^ \t\n\"'\\\\]+" s == null then
      "\"${replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s}\""
    else if s == "" then
      "\"\""
    else
      s;
  arg = s: quote (escape s);

  # Environment= from launch env operations. A unit starts from an empty
  # environment, so `default` is `set` and prepend/append have nothing to join.
  envLines =
    env:
    map (
      k:
      let
        op = env.${k};
      in
      if op ? unset then
        "UnsetEnvironment=${k}"
      else if op ? set then
        "Environment=${quote "${k}=${op.set}"}"
      else if op ? default then
        "Environment=${quote "${k}=${op.default}"}"
      else if op ? prepend then
        "Environment=${quote "${k}=${concatStringsSep ":" op.prepend}"}"
      else
        "Environment=${quote "${k}=${concatStringsSep ":" op.append}"}"
    ) (attrNames env);

  sortStrings = sort (a: b: a < b);

  # Where the renderer writes a service's app files: /usr/lib/<name>/<file>.
  # A module uses the same function for the paths it puts in argv.
  filesDir = name: "/usr/lib/${name}";

  build =
    svc:
    let
      credentials = svc.credentials or { };

      # a credential ref must name a declared credential, or the unit cannot start
      checkedRef =
        r:
        if credentials ? ${r.credential} then
          "${r.prefix or ""}%d/${r.credential}"
        else
          throw "golconda: service ${svc.name} references credential '${r.credential}' but declares only [${concatStringsSep ", " (attrNames credentials)}]";

      execStart = [
        (exe svc.app)
      ]
      ++ map (a: if isCredentialRef a then checkedRef a else arg a) (svc.app.argv or [ ]);

      user = isUser svc;
      userLines =
        if user then
          [ ]
        else if svc.user == "dynamic" then
          [ "DynamicUser=yes" ]
        else if svc.user == "root" then
          [ "User=root" ]
        else
          [ "User=${sysusersName svc.user}" ];

      unitSection = [
        "[Unit]"
        "Description=${svc.name}"
      ]
      ++ map (u: "After=${u}") (svc.after or [ ])
      ++ map (u: "Wants=${u}") (svc.wants or [ ]);

      serviceSection = [
        "[Service]"
        "ExecStart=${concatStringsSep " " execStart}"
      ]
      ++ envLines (svc.app.env or { })
      ++ map (n: "LoadCredentialEncrypted=${n}:${credentials.${n}}") (sortStrings (attrNames credentials))
      ++ map (d: "StateDirectory=${d}") (svc.state or [ ])
      ++ (if svc ? runtimeDirectory then [ "RuntimeDirectory=${svc.runtimeDirectory}" ] else [ ])
      ++ (if svc ? killMode then [ "KillMode=${svc.killMode}" ] else [ ])
      ++ userLines
      ++ sandboxLines.${svc.sandbox};

      wantedByTargets = svc.wantedBy or [ (if user then "default.target" else "multi-user.target") ];

      installSection = [
        "[Install]"
      ]
      ++ map (t: "WantedBy=${t}") wantedByTargets;

      text = concatStringsSep "\n" (concatLists [
        unitSection
        [ "" ]
        serviceSection
        [ "" ]
        installSection
      ]);

      # Static .wants symlinks: <unitDir>/<target>.wants/<unit> -> ../<unit>
      # These work without a first-boot step (unlike presets) and in the initrd too.
      unitFileName = "${svc.name}.service";
      unitDir = if user then "/usr/lib/systemd/user" else "/usr/lib/systemd/system";
      wantsLinks = builtins.listToAttrs (
        map (t: {
          name = "${unitDir}/${t}.wants/${unitFileName}";
          value = {
            target = "../${unitFileName}";
            kind = "explicit";
          };
        }) wantedByTargets
      );

      # the app's files, under /usr/lib/<name>/
      appFiles = svc.app.files or { };
      files = builtins.listToAttrs (
        map (f: {
          name = "${filesDir svc.name}/${f}";
          value = appFiles.${f};
        }) (attrNames appFiles)
      );
    in
    {
      # A system unit is a typed `units` entry; a user unit is a file under
      # /usr/lib/systemd/user, so the composer's duplicate check covers both.
      links = wantsLinks;
      # StateDirectory= creates and owns the state; no tmpfiles lines needed
      packages = [ svc.app.package ];
    }
    // (
      if user then
        {
          files = files // {
            "${unitDir}/${unitFileName}" = text + "\n";
          };
        }
      else
        {
          inherit files;
          units.${unitFileName} = text + "\n";
          sysusers = if isSysusersLine svc.user then [ svc.user ] else [ ];
        }
    );

  # service -> fragment; type-checks first, so a bad value throws with the
  # korora message instead of failing somewhere inside the text.
  render = svc: service.check svc (build svc);
in
{
  inherit
    service
    name
    user
    sandbox
    sandboxLines
    killMode
    scope
    escape
    filesDir
    render
    ;
  inherit (appLib)
    app
    credentialRef
    ;
  credential = n: { credential = n; };
  # `-o RevokedKeys=%d/krl` style: credentialArg "RevokedKeys=" "krl"
  credentialArg = prefix: n: {
    credential = n;
    inherit prefix;
  };
}
