# The service type and its systemd renderer. A service is an `app` (app.nix)
# plus what only a unit has: credentials, state, user, sandbox, ordering.
# `render service` returns a fragment (fragment.nix) for the composer. No
# enable flag: a service in `fragments` is on. Two instances are two names;
# the composer refuses a duplicate unit. Report:
# ~/spikes/research-services/REPORT.md section 3.
#
#   let s = import ../../lib/service.nix { inherit types; };
#   in s.render { name = "foo"; app = { package = pkg; }; user = "dynamic"; sandbox = "strict"; }
{ types }:
let
  appLib = import ./app.nix { inherit types; };
  inherit (import ./var.nix { inherit types; }) word;
  inherit (appLib)
    app
    credentialRef
    exe
    filesPlaceholder
    isCredentialRef
    wrapApp
    ;
  inherit (types)
    attrsOf
    enum
    listOf
    optionalAttr
    string
    struct
    typedef'
    union
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

  service = struct "service" {
    inherit
      name
      app
      user
      sandbox
      ;
    # unit-only arguments after app.argv: strings or { credential = "n"; prefix ? ""; }
    # (<prefix>%d/n); default [ ]
    extraArgv = optionalAttr (
      listOf (union [
        string
        credentialRef
      ])
    );
    # credential name -> credstore id: LoadCredentialEncrypted=name:id; default { }
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
    # targets that pull in this unit; default [ "multi-user.target" ]
    # generates static .wants symlinks; [Install] section kept for admin overrides
    wantedBy = optionalAttr (listOf targetName);
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

  # The unit text and the parts both renderers share. `argv` is the complete
  # ExecStart= list after the executable; `envLines` is Environment= or
  # nothing, by whether the launch record carries the environment.
  buildUnit =
    {
      svc,
      argv,
      envLines,
    }:
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
      ++ argv
      ++ map (a: if isCredentialRef a then checkedRef a else arg a) (svc.extraArgv or [ ]);

      userLines =
        if svc.user == "dynamic" then
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
      ++ envLines
      ++ map (n: "LoadCredentialEncrypted=${n}:${credentials.${n}}") (sortStrings (attrNames credentials))
      ++ map (d: "StateDirectory=${d}") (svc.state or [ ])
      ++ (if svc ? runtimeDirectory then [ "RuntimeDirectory=${svc.runtimeDirectory}" ] else [ ])
      ++ (if svc ? killMode then [ "KillMode=${svc.killMode}" ] else [ ])
      ++ userLines
      ++ sandboxLines.${svc.sandbox};

      wantedByTargets = svc.wantedBy or [ "multi-user.target" ];

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

      # Static .wants symlinks: /usr/lib/systemd/system/<target>.wants/<unit> -> ../<unit>
      # These work without a first-boot step (unlike presets) and in the initrd too.
      unitFileName = "${svc.name}.service";
      wantsLinks = map (t: {
        path = "/usr/lib/systemd/system/${t}.wants/${unitFileName}";
        target = "../${unitFileName}";
      }) wantedByTargets;
    in
    {
      units.${unitFileName} = text + "\n";
      sysusers = if isSysusersLine svc.user then [ svc.user ] else [ ];
      links = wantsLinks;
    };

  # Build without wrap: config files go to /usr/lib/<name>/, argv is on ExecStart.
  buildUnwrapped =
    svc:
    let
      filesDir = "/usr/lib/${svc.name}";
      expandFiles = replaceStrings [ filesPlaceholder ] [ filesDir ];
      files = svc.app.files or { };
    in
    buildUnit {
      inherit svc;
      argv = map (a: arg (expandFiles a)) (svc.app.argv or [ ]);
      envLines = envLines (svc.app.env or { });
    }
    // {
      files = builtins.listToAttrs (
        map (f: {
          name = "${filesDir}/${f}";
          value = files.${f};
        }) (attrNames files)
      );
      # StateDirectory= creates and owns the state; no tmpfiles lines needed
      packages = [ svc.app.package ];
    };

  # Build with wrap: config files are in the wrapped output; argv and env are
  # in the launch record; only extraArgv (credential refs) stays on ExecStart.
  buildWrapped =
    wrap: svc:
    buildUnit {
      inherit svc;
      argv = [ ];
      envLines = [ ];
    }
    // {
      # No files: they are in the wrapped output's share/wrap/<pkgname>/
      files = { };
      # The wrapped derivation goes into the farm, not the original package
      packages = [ (wrapApp wrap svc.app) ];
    };

  # service -> fragment; type-checks first, so a bad value throws with the
  # korora message instead of failing somewhere inside the text.
  # When `wrap` is provided (repkgs' set.wrap), the wrapped binary carries
  # argv, env and files; only extraArgv stays on ExecStart.
  render = svc: service.check svc (buildUnwrapped svc);
  renderWrapped = wrap: svc: service.check svc (buildWrapped wrap svc);
in
{
  inherit
    service
    name
    user
    sandbox
    sandboxLines
    killMode
    escape
    render
    renderWrapped
    ;
  inherit (appLib)
    app
    credentialRef
    file
    wrapApp
    ;
  credential = n: { credential = n; };
  # `-o RevokedKeys=%d/krl` style: credentialArg "RevokedKeys=" "krl"
  credentialArg = prefix: n: {
    credential = n;
    inherit prefix;
  };
}
