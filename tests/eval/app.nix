# Checks of app.argv, app.files, app.program, the /usr/bin farm and the app's files under /usr/lib/<name>.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  a,
  check,
  compose,
  f,
  hasInfix,
  openssh,
  s,
  standIn,
  stubSet,
  throws,
  withBin,
  ...
}:
let
  inherit (builtins)
    all
    deepSeq
    elem
    tryEval
    ;

  farmOf =
    packages:
    (
      (f.modules {
        options = {
          "/pkgs".target = stubSet;
          "/system" = {
            name = "farm";
            version = "20261031.1";
            fragments = [ { inherit packages; } ];
          };
        };
      }).modules.system
        { }
    ).packages;
in
[
  # 2. one argv: strings and credential refs; a ref must name a declared credential
  (check "app.argv accepts a declared credential ref and renders it as %d" (
    hasInfix "\nExecStart=/usr/bin/jq -c %d/x.k\n"
      (s.render {
        name = "x";
        app = {
          package = standIn;
          argv = [
            "-c"
            (s.credential "k")
          ];
        };
        credentials.k = "x.k";
        user = "dynamic";
        sandbox = "strict";
      }).units."x.service"
  ))
  (check "app.argv refuses an undeclared credential ref and a malformed one" (
    let
      base = {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
      };
    in
    throws (s.render (base // { app.argv = [ (s.credential "k") ]; }))
    && throws (
      s.render (
        base
        // {
          app.argv = [
            {
              credential = "k";
              extra = 1;
            }
          ];
          credentials.k = "x.k";
        }
      )
    )
    && throws (s.render (base // { app.argv = [ 1 ]; }))
  ))
  (check "app.argv refuses an argument with a newline" (
    throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          argv = [ "a\nb" ];
        };
        user = "dynamic";
        sandbox = "strict";
      }
    )
  ))
  (check "app.argv accepts spaces and quotes (escaped by the renderer)" (
    !throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          argv = [
            "a b"
            "c\"d"
          ];
        };
        user = "dynamic";
        sandbox = "strict";
      }
    )
  ))
  (check "app.argv renders a prefixed credential ref" (
    hasInfix " -o RevokedKeys=%d/x.k\n"
      (s.render {
        name = "x";
        app = {
          package = standIn;
          argv = [
            "-o"
            (s.credentialArg "RevokedKeys=" "k")
          ];
        };
        credentials.k = "x.k";
        user = "dynamic";
        sandbox = "strict";
      }).units."x.service"
  ))
  (check "a credential prefix is one plain word" (
    throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          argv = [ (s.credentialArg "Revoked Keys=" "k") ];
        };
        credentials.k = "x.k";
        user = "dynamic";
        sandbox = "strict";
      }
    )
  ))
  (check "service and app refuse an unknown field: extraArgv is gone" (
    let
      base = {
        name = "x";
        app.package = standIn;
        user = "dynamic";
        sandbox = "strict";
      };
    in
    throws (s.render (base // { extraArgv = [ "-D" ]; }))
    && throws (s.render (base // { app.wraps = standIn; }))
    && hasInfix "extraArgv" (s.service.verify (base // { extraArgv = [ "-D" ]; }))
    && !throws (s.render base)
  ))
  (check "render writes the app's files under /usr/lib/<name>, directories included" (
    let
      frag = s.render {
        name = "foo";
        app = {
          package = standIn;
          argv = [
            "-f"
            "${s.filesDir "foo"}/foo.conf"
          ];
          files = {
            "foo.conf" = "a=1\n";
            "keys/root" = "k\n";
          };
        };
        user = "dynamic";
        sandbox = "strict";
      };
    in
    s.filesDir "foo" == "/usr/lib/foo"
    && frag.files."/usr/lib/foo/foo.conf" == "a=1\n"
    && frag.files."/usr/lib/foo/keys/root" == "k\n"
    && hasInfix "\nExecStart=/usr/bin/jq -f /usr/lib/foo/foo.conf\n" frag.units."foo.service"
    && frag.packages == [ standIn ]
  ))
  # 2b. an app file holds no per-machine value: a credential path or a key is refused,
  # and the message names the file (a.files.verify is null or the message)
  (check "app.files accepts a plain config" (
    a.files.verify {
      "sshd_config" =
        "Port 22\nAuthorizedKeysFile .ssh/authorized_keys /usr/lib/sshd/authorized_keys.%u\n";
      "motd" = "welcome";
    } == null
  ))
  (check "app.files refuses each per-machine marker and names the file" (
    all (
      m:
      let
        err = a.files.verify {
          ok = "Port 22\n";
          "bad.conf" = "Key ${m}x\n";
        };
      in
      err != null && hasInfix "'bad.conf'" err && hasInfix m err
    ) a.perMachineMarkers
    &&
      a.perMachineMarkers == [
        "%d/"
        "$CREDENTIALS_DIRECTORY"
        "/etc/credstore"
        "-----BEGIN"
        "PRIVATE KEY"
      ]
  ))
  (check "render refuses an app file with a credential path" (
    throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          files."x.conf" = "RevokedKeys %d/krl\n";
        };
        user = "dynamic";
        sandbox = "strict";
      }
    )
  ))
  (check "render refuses an app file with a private key" (
    throws (
      s.render {
        name = "x";
        app = {
          package = standIn;
          files."key" = "-----BEGIN OPENSSH PRIVATE KEY-----\n";
        };
        user = "dynamic";
        sandbox = "strict";
      }
    )
  ))
  (check "app.files must be text" (a.files.verify { x = 1; } != null))
  # 3b. two packages with one /usr/bin name are a composer error
  (check "farm refuses one name in two packages" (
    !(tryEval (
      deepSeq (farmOf [
        (withBin "a-1" [ "x" ])
        (withBin "b-1" [
          "y"
          "x"
        ])
      ]) true
    )).success
  ))
  (check "farm accepts distinct names; the same package twice is one package, one link" (
    let
      a = withBin "a-1" [ "x" ];
      b = withBin "b-1" [ "y" ];
      packages = [
        a
        b
        a
      ];
      result = compose [ { inherit packages; } ];
    in
    # farmOf calls the composer alone (no components): the requested packages are there
    elem a (farmOf packages)
    && elem b (farmOf packages)
    # the links include these with the right targets
    &&
      result.links."/usr/bin/x" == {
        target = "${a}/bin/x";
        kind = "package";
      }
    &&
      result.links."/usr/bin/y" == {
        target = "${b}/bin/y";
        kind = "package";
      }
  ))
  # 5b. app.program and the /usr/bin farm
  (check "app.program defaults to the first bin and must be one of them" (
    a.binName { package = openssh; } == "ssh"
    &&
      a.binName {
        package = openssh;
        program = "sshd";
      } == "sshd"
    && a.binName { package = standIn; } == "jq"
    &&
      a.app.verify {
        package = openssh;
        program = "sshd";
      } == null
    &&
      a.app.verify {
        package = openssh;
        program = "httpd";
      } != null
    && hasInfix "openssh-10.6p1" (
      a.app.verify {
        package = openssh;
        program = "httpd";
      }
    )
  ))
  (check "farm: a second package with the same program clashes, whatever it is" (
    !(tryEval (
      deepSeq (farmOf [
        (withBin "dropbear-1" [ "sshd" ])
        openssh
      ]) true
    )).success
    && !(tryEval (
      deepSeq (farmOf [
        openssh
        (openssh // { outPath = "/nix/store/openssh-10.6p1-other"; })
      ]) true
    )).success
  ))
]
