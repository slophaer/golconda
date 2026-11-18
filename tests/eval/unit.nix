# Checks of unit enablement (wantedBy, [Install]) and the required service user.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  hasInfix,
  s,
  standIn,
  throws,
  v,
  ...
}:
[
  # 6. Unit enablement: wantedBy renders .wants links and [Install] text
  (check "wantedBy: service has .wants link" (
    let
      svc = s.render {
        name = "test-svc";
        app.package = standIn;
        user = "root";
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
        user = "root";
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
        user = "root";
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
        user = "root";
        sandbox = "strict";
        wantedBy = [ "multi-user" ]; # missing .target
      }
    )
  ))
  (check "service: user is required" (
    throws (
      s.render {
        name = "x";
        app.package = standIn;
        sandbox = "strict";
      }
    )
    && (s.render {
      name = "x";
      app.package = standIn;
      user = "root";
      sandbox = "strict";
    }).units
      ? "x.service"
  ))
]
