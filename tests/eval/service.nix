# Checks of the service renderer: escaping, user, killMode, runtimeDirectory, sandbox, env operations, and
# the guards that keep a typed scalar from adding a unit directive.
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
let
  inherit (builtins) all deepSeq tryEval;
in
[
  (check "render: Environment= from env operations" (
    hasInfix "\nEnvironment=HOME=/var/lib/x\n"
      (s.render {
        name = "x";
        app = {
          package = standIn;
          env.HOME.set = "/var/lib/x";
        };
        user = "dynamic";
        sandbox = "strict";
      }).units."x.service"
  ))
  # 4. systemd escaping and the other type rules
  (check "render escapes % and $" (
    hasInfix "ExecStart=/usr/bin/jq 50%% $$HOME \"a b\""
      (s.render {
        name = "esc";
        app = {
          package = standIn;
          argv = [
            "50%"
            "$HOME"
            "a b"
          ];
        };
        user = "root";
        sandbox = "trusted";
      }).units."esc.service"
  ))
  (check "user must be dynamic, root or a sysusers line" (
    throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "bob";
        sandbox = "strict";
      }
    )
  ))
  (check "killMode and runtimeDirectory render; neither by default" (
    let
      base = {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
      };
      plain = (s.render base).units."x.service";
      extra =
        (s.render (
          base
          // {
            killMode = "mixed";
            runtimeDirectory = "x";
          }
        )).units."x.service";
    in
    !hasInfix "KillMode=" plain
    && !hasInfix "RuntimeDirectory=" plain
    && hasInfix "\nRuntimeDirectory=x\nKillMode=mixed\n" extra
  ))
  (check "killMode is an enum and runtimeDirectory one component" (
    throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        killMode = "none";
      }
    )
    && throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        runtimeDirectory = "a/b";
      }
    )
    && throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        runtimeDirectory = [ "a" ];
      }
    )
  ))
  # one component rule: RuntimeDirectory=.. would be /run itself, a var named . would
  # share /var/lib/golconda/vars with every var
  (check "runtimeDirectory, a var name and a var file refuse . and .." (
    all
      (
        c:
        throws (
          s.render {
            name = "x";
            app.package = standIn;
            user = "dynamic";
            sandbox = "strict";
            runtimeDirectory = c;
          }
        )
        && throws (
          v.render {
            name = c;
            secrets = [ "key" ];
            script = "";
          }
        )
        && throws (
          v.render {
            name = "x";
            secrets = [ c ];
            script = "";
          }
        )
        && v.word.verify c == (import ../../modules/lib/path.nix).componentError c
      )
      [
        "."
        ".."
      ]
    # a name that only starts with dots is still one component
    && !throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        runtimeDirectory = "...x";
      }
    )
  ))
  (check "sandbox is an enum" (
    throws (
      s.render {
        name = "x";
        app.package = standIn;
        user = "root";
        sandbox = "lax";
      }
    )
  ))
  (check "env operation has one key" (
    throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          env.X = {
            set = "1";
            unset = true;
          };
        };
        user = "root";
        sandbox = "strict";
      }
    )
  ))
  (check "env: unset is true-only and renders UnsetEnvironment=" (
    let
      unit =
        env:
        (s.render {
          name = "x";
          app = {
            package = standIn;
            inherit env;
          };
          user = "root";
          sandbox = "strict";
        }).units."x.service";
    in
    hasInfix "\nUnsetEnvironment=OLD\n" (unit {
      OLD.unset = true;
    })
    && throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          env.OLD.unset = false;
        };
        user = "root";
        sandbox = "strict";
      }
    )
  ))
  (check "env: default, prepend and append are not operations" (
    all
      (
        env:
        throws (
          s.render {
            name = "x";
            app = {
              package = standIn;
              inherit env;
            };
            user = "root";
            sandbox = "strict";
          }
        )
      )
      [
        { PATH.default = "/usr/lib/foo/bin"; }
        { PATH.prepend = [ "/usr/lib/foo/bin" ]; }
        { PATH.append = [ "/usr/lib/foo/bin" ]; }
      ]
  ))
  (check "render: .wants links and [Install] follow wantedBy" (
    let
      frag = s.render {
        name = "w";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
        wantedBy = [ "sysinit.target" ];
      };
    in
    frag.links == {
      "/usr/lib/systemd/system/sysinit.target.wants/w.service" = {
        target = "../w.service";
        kind = "explicit";
      };
    }
    && hasInfix "[Install]\nWantedBy=sysinit.target\n" frag.units."w.service"
  ))
  # A typed scalar that lands in unit text cannot add a directive
  (check "unit: a line break in a typed scalar cannot add a directive" (
    let
      unitThrows =
        extra:
        !(tryEval (
          deepSeq (s.render (
            {
              name = "x";
              app = {
                package = standIn;
              };
              user = "root";
              sandbox = "default";
            }
            // extra
          )) true
        )).success;
    in
    # the probe: an env value that ends Environment= and starts ExecStartPre=
    unitThrows {
      app = {
        package = standIn;
        env.X.set = "a\nExecStartPre=/usr/bin/false";
      };
    }
    && unitThrows {
      app = {
        package = standIn;
        env."A B" = {
          set = "x";
        };
      };
    }
    && unitThrows { state = [ "a b" ]; }
    && unitThrows { state = [ "../etc" ]; }
    && unitThrows {
      credentials = {
        a = "../x";
      };
    }
    && unitThrows { after = [ "network.target\nRequires=evil.service" ]; }
    && unitThrows { wants = [ "not-a-unit" ]; }
    # positive: the same fields with plain values render
    && !(unitThrows { state = [ "foo" ]; })
  ))
  (check "unit: Environment= doubles % (a specifier) and keeps $ (literal)" (
    let
      u =
        (s.render {
          name = "x";
          app = {
            package = standIn;
            env = {
              HOME.set = "%h";
              VAR.set = "$HOME";
              PATH.set = "/usr/lib/foo/bin";
            };
          };
          user = "root";
          sandbox = "default";
        }).units."x.service";
    in
    hasInfix "\nEnvironment=HOME=%%h\n" u
    && hasInfix "\nEnvironment=VAR=$HOME\n" u
    && hasInfix "\nEnvironment=PATH=/usr/lib/foo/bin\n" u
  ))
  # a credential fallback: public text PID 1 gives the service when the sealed credential is not
  # in the credstore (SetCredential= under the same id, systemd.exec(5)); a backslash and a line
  # break are escaped, because PID 1 unescapes the value (cunescape) and a line ends the directive
  (check "render: a credential fallback is SetCredential= under the credential's id, escaped" (
    let
      u =
        (s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [ (s.credential "krl") ];
          };
          user = "root";
          sandbox = "default";
          credentials.krl = "foo-krl.krl";
          credentialFallbacks.krl = "# none yet\nssh-ed25519 AAAA a\\b\n";
        }).units."x.service";
    in
    hasInfix (
      "\nLoadCredentialEncrypted=foo-krl.krl\n"
      + "SetCredential=foo-krl.krl:# none yet\\nssh-ed25519 AAAA a\\\\b\\n\n"
    ) u
  ))
  (check "render: a credential fallback must name a declared credential, and hold text" (
    let
      withFallback =
        credentials: fallbacks:
        s.render {
          name = "x";
          app = {
            package = standIn;
          };
          user = "root";
          sandbox = "default";
          inherit credentials;
          credentialFallbacks = fallbacks;
        };
    in
    # the positive case composes, so the refusals below have teeth
    !(throws (withFallback { krl = "foo-krl.krl"; } { krl = "x"; }))
    && throws (withFallback { krl = "foo-krl.krl"; } { other = "x"; })
    # systemd ignores SetCredential=ID: with no value, and then the load fails as before
    && throws (withFallback { krl = "foo-krl.krl"; } { krl = ""; })
    # a control character other than a line break would reach the unit file raw
    && throws (withFallback { krl = "foo-krl.krl"; } { krl = "a\rb"; })
    && throws (withFallback { krl = "foo-krl.krl"; } { krl = 1; })
  ))
]
