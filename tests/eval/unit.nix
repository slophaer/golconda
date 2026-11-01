# Checks of unit enablement (wantedBy, [Install]), user-scope services and the system/user scope rules.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  filesThrow,
  hasInfix,
  s,
  standIn,
  throws,
  v,
  ...
}:
let
  inherit (builtins) attrNames deepSeq tryEval;
in
[
  # 6. Unit enablement: wantedBy renders .wants links and [Install] text
  (check "wantedBy: service has .wants link" (
    let
      svc = s.render {
        name = "test-svc";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
      };
    in
    svc.links."/usr/lib/systemd/system/multi-user.target.wants/test-svc.service".target
    == "../test-svc.service"
  ))
  (check "wantedBy: [Install] section has WantedBy line" (
    let
      svc = s.render {
        name = "test-svc";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
      };
    in
    hasInfix "[Install]\nWantedBy=multi-user.target" svc.units."test-svc.service"
  ))
  (check "wantedBy: custom targets" (
    let
      svc = s.render {
        name = "early-svc";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        wantedBy = [
          "sysinit.target"
          "basic.target"
        ];
      };
    in
    svc.links ? "/usr/lib/systemd/system/sysinit.target.wants/early-svc.service"
    && svc.links ? "/usr/lib/systemd/system/basic.target.wants/early-svc.service"
    && hasInfix "WantedBy=sysinit.target" svc.units."early-svc.service"
    && hasInfix "WantedBy=basic.target" svc.units."early-svc.service"
  ))
  (check "wantedBy: var unit has .wants link" (
    let
      varFrag = v.render {
        name = "test-var";
        secrets = [ "key" ];
        script = "echo";
      };
    in
    varFrag.links."/usr/lib/systemd/system/multi-user.target.wants/golconda-var-test-var.service" == {
      target = "../golconda-var-test-var.service";
      kind = "explicit";
    }
  ))
  (check "wantedBy: var unit [Install] section" (
    let
      varFrag = v.render {
        name = "test-var";
        secrets = [ "key" ];
        script = "echo";
      };
    in
    hasInfix "[Install]\nWantedBy=multi-user.target" varFrag.units."golconda-var-test-var.service"
  ))
  (check "wantedBy: bad target name rejected" (
    throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        wantedBy = [ "multi-user" ]; # missing .target
      }
    )
  ))
  # 6b. user scope: the unit is a file under /usr/lib/systemd/user
  (check "user service: file under systemd/user, default.target wants, no User=" (
    let
      frag = s.render {
        name = "agent";
        scope = "user";
        app.package = standIn;
        sandbox = "default";
        state = [ "agent" ];
      };
      path = "/usr/lib/systemd/user/agent.service";
      text = frag.files.${path};
      composed = compose [ frag ];
    in
    !(frag ? units)
    && !(frag ? sysusers)
    && hasInfix "\nExecStart=/usr/bin/jq\n" text
    && hasInfix "\nStateDirectory=agent\n" text
    && !hasInfix "User=" text
    && hasInfix "[Install]\nWantedBy=default.target\n" text
    &&
      frag.links == {
        "/usr/lib/systemd/user/default.target.wants/agent.service" = {
          target = "../agent.service";
          kind = "explicit";
        };
      }
    && composed.files.${path}.mode == "0644"
    # /base contributes its own units; a user service adds none to `units`
    && !(composed.units ? "agent.service")
    && composed.links ? "/usr/lib/systemd/user/default.target.wants/agent.service"
  ))
  (check "user service: files beside the unit and explicit wantedBy" (
    let
      frag = s.render {
        name = "agent";
        scope = "user";
        app = {
          package = standIn;
          files."agent.conf" = "x";
        };
        sandbox = "default";
        wantedBy = [ "graphical-session.target" ];
      };
    in
    hasInfix "WantedBy=graphical-session.target" frag.files."/usr/lib/systemd/user/agent.service"
    && frag.files."/usr/lib/agent/agent.conf" == "x"
    && frag.packages == [ standIn ]
    &&
      attrNames frag.links == [
        "/usr/lib/systemd/user/graphical-session.target.wants/agent.service"
      ]
  ))
  (check "user service: refuses user, credentials and a credential ref" (
    let
      base = {
        name = "agent";
        scope = "user";
        app.package = standIn;
        sandbox = "default";
      };
      verify = extra: s.service.verify (base // extra);
      fails = extra: !(tryEval (deepSeq (s.render (base // extra)).files true)).success;
    in
    hasInfix "`user` is refused" (verify {
      user = "root";
    })
    && fails { user = "root"; }
    && fails { user = "dynamic"; }
    && hasInfix "system manager" (verify {
      credentials.k = "x.k";
    })
    && fails { credentials.k = "x.k"; }
    && fails { app.argv = [ (s.credential "k") ]; }
    && verify { } == null
  ))
  (check "system service: user is required and scope is an enum" (
    hasInfix "names its user" (
      s.service.verify {
        name = "x";
        app.package = standIn;
        sandbox = "strict";
      }
    )
    && throws (
      s.render {
        name = "x";
        app.package = standIn;
        sandbox = "strict";
      }
    )
    && throws (
      s.render {
        name = "x";
        scope = "session";
        app.package = standIn;
        sandbox = "strict";
      }
    )
    && (s.render {
      name = "x";
      scope = "system";
      app.package = standIn;
      user = "root";
      sandbox = "strict";
    }).units
      ? "x.service"
  ))
  (check "user service: a second module at the same unit is a composer error" (
    let
      frag = s.render {
        name = "agent";
        scope = "user";
        app.package = standIn;
        sandbox = "default";
      };
    in
    filesThrow [
      frag
      frag
    ]
    && !(tryEval (
      deepSeq
        (compose [
          frag
          frag
        ]).links
        true
    )).success
  ))
]
