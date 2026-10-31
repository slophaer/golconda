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

  # Build without wrap: config files go to /usr/lib/<name>/, argv is on ExecStart.
  buildUnwrapped =
    svc:
    let
      filesDir = "/usr/lib/${svc.name}";
      expandFiles = replaceStrings [ filesPlaceholder ] [ filesDir ];
      extraArgv = svc.extraArgv or [ ];
      credentials = svc.credentials or { };
      files = svc.app.files or { };

      # a credential ref must name a declared credential, or the unit cannot start
      checkedRef =
        r:
        if credentials ? ${r.credential} then
          "${r.prefix or ""}%d/${r.credential}"
        else
          throw "golconda: service ${svc.name} references credential '${r.credential}' but declares only [${concatStringsSep ", " (attrNames credentials)}]";

      argv = [
        (exe svc.app)
      ]
      ++ map (a: arg (expandFiles a)) (svc.app.argv or [ ])
      ++ map (a: if isCredentialRef a then checkedRef a else arg a) extraArgv;

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
        "ExecStart=${concatStringsSep " " argv}"
      ]
      ++ envLines (svc.app.env or { })
      ++ map (n: "LoadCredentialEncrypted=${n}:${credentials.${n}}") (sortStrings (attrNames credentials))
      ++ map (d: "StateDirectory=${d}") (svc.state or [ ])
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
      units."${svc.name}.service" = text + "\n";
      files = builtins.listToAttrs (
        map (f: {
          name = "${filesDir}/${f}";
          value = files.${f};
        }) (attrNames files)
      );
      sysusers = if isSysusersLine svc.user then [ svc.user ] else [ ];
      # StateDirectory= creates and owns the state; no tmpfiles lines needed
      packages = [ svc.app.package ];
      links = wantsLinks;
    };

  # Build with wrap: config files are in the wrapped output; argv is in the
  # launch record; only extraArgv (credential refs) stays on ExecStart.
  buildWrapped =
    wrap: svc:
    let
      wrapped = wrapApp wrap svc.app;
      extraArgv = svc.extraArgv or [ ];
      credentials = svc.credentials or { };

      checkedRef =
        r:
        if credentials ? ${r.credential} then
          "${r.prefix or ""}%d/${r.credential}"
        else
          throw "golconda: service ${svc.name} references credential '${r.credential}' but declares only [${concatStringsSep ", " (attrNames credentials)}]";

      # Only the wrapped binary and extraArgv; argv/env/files are in the launch record
      argv = [
        (exe svc.app)
      ]
      ++ map (a: if isCredentialRef a then checkedRef a else arg a) extraArgv;

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

      # No Environment= lines: the launch record carries env
      serviceSection = [
        "[Service]"
        "ExecStart=${concatStringsSep " " argv}"
      ]
      ++ map (n: "LoadCredentialEncrypted=${n}:${credentials.${n}}") (sortStrings (attrNames credentials))
      ++ map (d: "StateDirectory=${d}") (svc.state or [ ])
      ++ userLines
      ++ sandboxLines.${svc.sandbox};

      installSection = [
        "[Install]"
        "WantedBy=multi-user.target"
      ];

      text = concatStringsSep "\n" (concatLists [
        unitSection
        [ "" ]
        serviceSection
        [ "" ]
        installSection
      ]);
    in
    {
      units."${svc.name}.service" = text + "\n";
      # No files: they are in the wrapped output's share/wrap/<pkgname>/
      files = { };
      sysusers = if isSysusersLine svc.user then [ svc.user ] else [ ];
      # The wrapped derivation goes into the farm, not the original package
      packages = [ wrapped ];
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
