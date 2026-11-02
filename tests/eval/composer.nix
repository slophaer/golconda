# Checks of the composer: typed units and files, duplicates, reserved and non-canonical paths.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  f,
  filesOf,
  filesThrow,
  fr,
  hasInfix,
  merge,
  s,
  standIn,
  stubSet,
  system,
  throws,
  ...
}:
let
  inherit (builtins)
    all
    deepSeq
    elem
    tryEval
    ;
in
[
  # 1b. a file is text (mode 0644) or { text; mode; }; the composer emits one shape
  (check "files: a string is a file with mode 0644" (
    (filesOf [ { files."/usr/lib/a/conf" = "x"; } ])."/usr/lib/a/conf" == {
      text = "x";
      mode = "0644";
    }
  ))
  (check "files: a record keeps its mode" (
    (filesOf [
      {
        files."/usr/lib/a/run" = {
          text = "#!/bin/sh\n";
          mode = "0755";
        };
      }
    ])."/usr/lib/a/run".mode == "0755"
  ))
  (check "files: a record without mode is 0644" (
    (filesOf [
      {
        files."/usr/lib/a/conf" = {
          text = "x";
        };
      }
    ])."/usr/lib/a/conf".mode == "0644"
  ))
  (check "files: a bad mode is a type error" (
    filesThrow [
      {
        files."/usr/lib/a/run" = {
          text = "x";
          mode = "rwxr-xr-x";
        };
      }
    ]
    && filesThrow [
      {
        files."/usr/lib/a/run" = {
          text = "x";
          mode = "755";
        };
      }
    ]
    && filesThrow [
      {
        files."/usr/lib/a/run" = {
          text = "x";
          mode = 493;
        };
      }
    ]
  ))
  (check "files: a record needs text and nothing else" (
    filesThrow [
      {
        files."/usr/lib/a/run" = {
          mode = "0755";
        };
      }
    ]
    && filesThrow [
      {
        files."/usr/lib/a/run" = {
          text = "x";
          source = ../../nix/tests.nix;
        };
      }
    ]
  ))
  (check "files: a string and a record for one path are a duplicate" (filesThrow [
    { files."/usr/lib/a/conf" = "x"; }
    {
      files."/usr/lib/a/conf" = {
        text = "x";
        mode = "0755";
      };
    }
  ]))
  # 3. a duplicate unit or file across two fragments is a composer error
  (check "composer refuses a duplicate unit" (
    throws (
      (f.modules {
        options."/system" = {
          name = "dup";
          version = "20261031.1";
          fragments = [
            { units."a.service" = "[Unit]\n"; }
            { units."a.service" = "[Service]\n"; }
          ];
        };
      }).modules.system
        { }
    )
  ))
  # 3a. typed units: the name has a unit suffix, the text a section header
  (check "units: every unit suffix is accepted, a template name too" (
    let
      r = compose [
        {
          units = builtins.listToAttrs (
            map (sfx: {
              name = "a.${sfx}";
              value = "[Unit]\nDescription=a\n";
            }) fr.unitSuffixes
          );
        }
        { units."getty@.service" = "[Service]\nExecStart=/usr/bin/agetty %I\n"; }
      ];
    in
    # /base is implicit and brings its own units (golconda-health-network.service);
    # assert that these names are present rather than a total count
    all (n: r.units ? ${n}) (map (sfx: "a.${sfx}") fr.unitSuffixes ++ [ "getty@.service" ])
    &&
      fr.unitSuffixes == [
        "service"
        "target"
        "socket"
        "timer"
        "path"
        "mount"
        "slice"
      ]
  ))
  (check "units: a bad suffix is a type error that names it" (
    throws (compose [ { units."a.conf" = "[Unit]\n"; } ])
    && throws (compose [ { units."a.service.bak" = "[Unit]\n"; } ])
    && throws (compose [ { units."a b.service" = "[Unit]\n"; } ])
    && hasInfix "'a.conf'" (fr.units.verify { "a.conf" = "[Unit]\n"; })
  ))
  (check "units: empty text or text without a section header is a type error" (
    throws (compose [ { units."a.service" = ""; } ])
    && throws (compose [ { units."a.service" = "Description=a\nExecStart=/usr/bin/a\n"; } ])
    && throws (compose [ { units."a.service" = 1; } ])
    && hasInfix "in unit 'a.service'" (fr.units.verify { "a.service" = ""; })
  ))
  (check "composer refuses a duplicate file" (filesThrow [
    { files."/usr/lib/foo/config" = "a"; }
    { files."/usr/lib/foo/config" = "b"; }
  ]))
  (check "composer: the fixed sbin alias rejects files with bin guidance" (
    let
      frags = [
        {
          name = "/services/alias-test";
          files."/usr/bin/x" = "first";
          files."/usr/sbin/x" = "second";
        }
      ];
      msg = merge.duplicateError frags;
    in
    filesThrow frags
    && msg != null
    && hasInfix "/usr/sbin/x" msg
    && hasInfix "/services/alias-test" msg
    && hasInfix "/usr/bin" msg
    && filesThrow [ { files."/usr/sbin" = "x"; } ]
    && !(filesThrow [ { files."/usr/sbin-extra/x" = "x"; } ])
  ))
  (check "composer concatenates lists" (
    let
      result =
        (f.modules {
          options = {
            "/pkgs".target = stubSet;
            "/system" = {
              name = "cat";
              version = "20261031.1";
              fragments = [
                { sysusers = [ "a" ]; }
                { sysusers = [ "b" ]; }
              ];
            };
          };
        }).modules.system
          { };
    in
    # the composer alone (no components): the fragments' sysusers are there
    elem "a" result.sysusers && elem "b" result.sysusers
  ))
  # 7. Composer output includes links from services and vars
  (check "composer: merges links from services" (
    system.links ? "/usr/lib/systemd/system/multi-user.target.wants/sshd.service"
  ))
  (check "composer: merges links from vars" (
    system.links ? "/usr/lib/systemd/system/multi-user.target.wants/golconda-var-sshd-hostkey.service"
  ))
  # A path in the /usr tree is canonical, and the check runs
  # before any duplicate check, so a typo cannot alias another file or leave
  # /usr. These four spell /usr/lib/x and /usr/etc/x differently.
  (check "paths: a non-canonical file path is refused" (
    filesThrow [ { files."/usr/../etc/x" = "x"; } ]
    && filesThrow [ { files."/usr/lib/../x" = "x"; } ]
    && filesThrow [ { files."/usr//x" = "x"; } ]
    && filesThrow [ { files."/usr/lib/x/" = "x"; } ]
    && filesThrow [ { files."/usr/lib/x\ny" = "x"; } ]
    # positive: the canonical spelling of the same paths is accepted
    && !(filesThrow [ { files."/usr/lib/x" = "x"; } ])
  ))
  (check "paths: a non-canonical link path is refused, a canonical one kept" (
    let
      linksThrow =
        p:
        !(tryEval (
          deepSeq
            (compose [
              {
                links.${p} = {
                  target = "../x";
                  kind = "explicit";
                };
              }
            ]).links
            true
        )).success;
    in
    linksThrow "/usr/../etc/x"
    && linksThrow "/usr/lib//x"
    && linksThrow "/usr/lib/a/../x"
    && !(linksThrow "/usr/lib/x")
  ))
  (check "paths: an app file name cannot leave /usr/lib/<service>" (
    let
      renderThrows =
        app:
        !(tryEval (
          s.render {
            name = "x";
            inherit app;
            user = "root";
            sandbox = "default";
          }
        )).success;
    in
    renderThrows {
      package = standIn;
      files."../x" = "y";
    }
    && renderThrows {
      package = standIn;
      files."/etc/x" = "y";
    }
    # positive: a name may hold a directory below the service's own
    && !(renderThrows {
      package = standIn;
      files."principals/root" = "y";
    })
  ))
  # Units, files and links go into one /usr tree; a path two kinds
  # claim is an error that names both, not last-one-wins.
  (check "composer: a unit and a file at one installed path name both" (
    let
      msg = merge.duplicateError [
        {
          name = "/services/a";
          units."demo.service" = "[Unit]\n";
          files."/usr/lib/systemd/system/demo.service" = "text";
        }
      ];
    in
    msg != null
    && hasInfix "/usr/lib/systemd/system/demo.service defined twice" msg
    && hasInfix "unit 'demo.service' from /services/a" msg
    && hasInfix "file from /services/a" msg
  ))
  (check "composer: a unit and a link at one installed path name both" (
    let
      msg = merge.duplicateError [
        {
          units."demo.service" = "[Unit]\n";
          links."/usr/lib/systemd/system/demo.service" = {
            target = "../x.service";
            kind = "explicit";
          };
        }
      ];
    in
    msg != null
    && hasInfix "unit 'demo.service' from fragments[0]" msg
    && hasInfix "explicit link to ../x.service from fragments[0]" msg
  ))
  (check "composer: a path two kinds claim throws when composed" (
    filesThrow [
      {
        units."demo.service" = "[Unit]\n";
        files."/usr/lib/systemd/system/demo.service" = "x";
      }
    ]
    && filesThrow [
      {
        links."/usr/lib/x" = {
          target = "../y";
          kind = "explicit";
        };
        files."/usr/lib/x" = "x";
      }
    ]
    # positive: one claim per path composes
    && !(filesThrow [
      {
        units."demo.service" = "[Unit]\n";
        files."/usr/lib/systemd/system/x.service" = "x";
      }
    ])
  ))
  (check "composer: two fragments claiming one file name both module paths" (
    let
      msg = merge.duplicateError [
        {
          name = "/services/a";
          files."/usr/lib/foo.conf" = "a";
        }
        {
          name = "/services/b";
          files."/usr/lib/foo.conf" = "b";
        }
      ];
    in
    filesThrow [
      { files."/usr/lib/foo.conf" = "a"; }
      { files."/usr/lib/foo.conf" = "b"; }
    ]
    && msg == "golconda: /usr/lib/foo.conf defined twice: file from /services/a, file from /services/b"
  ))
  (check "composer: the paths the image builder writes are reserved" (
    filesThrow [ { files."/usr/lib/os-release" = "ID=x\n"; } ]
    && filesThrow [ { files."/usr/lib/sysusers.d/golconda.conf" = "u x -\n"; } ]
    && filesThrow [ { files."/usr/lib/tmpfiles.d/golconda.conf" = "d /x\n"; } ]
    && filesThrow [ { files."/usr/lib/golconda/sbom.json" = "{}"; } ]
    &&
      hasInfix "/usr/lib/os-release defined twice: file from lib/usr-tree/main.nu, file from /services/a"
        (
          merge.duplicateError [
            {
              name = "/services/a";
              files."/usr/lib/os-release" = "ID=x\n";
            }
          ]
        )
  ))
  (check "composer: the metadata the system writes is reserved" (
    filesThrow [ { files."/usr/lib/golconda/config.json" = "{}"; } ]
    && filesThrow [ { files."/usr/lib/golconda/schema.json" = "{}"; } ]
    && filesThrow [ { files."/usr/lib/golconda/attribution.json" = "{}"; } ]
    && filesThrow [ { files."/usr/lib/golconda/packages.json" = "[]"; } ]
    && filesThrow [
      {
        links."/usr/lib/golconda/config.json" = {
          target = "../x";
          kind = "explicit";
        };
      }
    ]
  ))
]
