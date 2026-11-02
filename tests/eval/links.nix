# Checks of the one links map: package links, the fragments' farm, dlopen and explicit links, and their clashes.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  fr,
  hasInfix,
  merge,
  openssh,
  standIn,
  withBin,
  ...
}:
let
  inherit (builtins) deepSeq elem tryEval;
in
[
  # 5. one links map: /usr/bin from packages, the fragments' farm, dlopen and
  # explicit links, one duplicate check that names both sources
  (check "links: a package with two bins is two package links" (
    let
      tool = withBin "tool-1" [
        "foo"
        "bar"
      ];
      result = compose [ { packages = [ tool ]; } ];
    in
    # compose includes /base links too; check that the tool's links are present
    result.links."/usr/bin/foo" == {
      target = "${tool}/bin/foo";
      kind = "package";
    }
    &&
      result.links."/usr/bin/bar" == {
        target = "${tool}/bin/bar";
        kind = "package";
      }
  ))
  (check "links: dlopen and explicit links pass through with their kinds" (
    let
      tss = withBin "libfoo-1" [ ];
      frag = {
        packages = [ tss ];
        links = {
          # use paths that don't collide with /base (which links every soname systemd dlopens)
          "/usr/lib/libfoo.so.1" = {
            target = "${tss}/lib/libfoo.so.1";
            kind = "dlopen";
          };
          "/usr/lib/systemd/system/sysinit.target.wants/a.service" = {
            target = "../a.service";
            kind = "explicit";
          };
        };
      };
      result = compose [ frag ];
    in
    # the fragment's links are present with correct kinds
    result.links."/usr/lib/libfoo.so.1".kind == "dlopen"
    && result.links."/usr/lib/systemd/system/sysinit.target.wants/a.service".kind == "explicit"
  ))
  (check "links: the target path, kind and shape are typed" (
    let
      bad = links: !(tryEval (deepSeq (compose [ { inherit links; } ]).links true)).success;
      ok = links: (tryEval (deepSeq (compose [ { inherit links; } ]).links true)).success;
    in
    bad {
      "/etc/motd" = {
        target = "/usr/lib/motd";
        kind = "explicit";
      };
    }
    && bad {
      "/usr/lib/x" = {
        target = "/nix/store/x";
        kind = "symlink";
      };
    }
    && bad {
      "/usr/lib/x" = {
        target = "/nix/store/x";
      };
    }
    && bad { "/usr/lib/x" = "/nix/store/x"; }
    && bad {
      "/usr/lib/x" = {
        target = "/nix/store/x";
        kind = "explicit";
        path = "/usr/lib/x";
      };
    }
    && bad [
      {
        path = "/usr/lib/x";
        target = "/nix/store/x";
      }
    ]
    && ok {
      "/usr/lib/x" = {
        target = "/nix/store/x";
        kind = "explicit";
      };
    }
    && hasInfix "'/etc/motd'" (
      fr.links.verify {
        "/etc/motd" = {
          target = "x";
          kind = "explicit";
        };
      }
    )
    && hasInfix "in link '/usr/lib/x'" (
      fr.links.verify {
        "/usr/lib/x" = {
          target = "x";
        };
      }
    )
  ))
  # one path, two links: a package link and an explicit link clash, and so do
  # two explicit links; neither may keep one of them in silence
  (check "links: a package link and an explicit link at one path clash, both named" (
    let
      frags = [
        { packages = [ standIn ]; }
        {
          links."/usr/bin/jq" = {
            target = "/nix/store/other/bin/jq";
            kind = "explicit";
          };
        }
      ];
      msg = merge.duplicateError frags;
    in
    !(tryEval (deepSeq (compose frags).links true)).success
    && !(tryEval (deepSeq (compose frags).packages true)).success
    && hasInfix "/usr/bin/jq defined twice" msg
    && hasInfix "package jq" msg
    && hasInfix "explicit link to /nix/store/other/bin/jq" msg
  ))
  (check "links: two explicit links at one path clash, both targets named" (
    let
      at = target: {
        links."/usr/lib/x" = {
          inherit target;
          kind = "explicit";
        };
      };
      frags = [
        (at "a")
        (at "b")
      ];
      msg = merge.duplicateError frags;
    in
    !(tryEval (deepSeq (compose frags).links true)).success
    && hasInfix "/usr/lib/x defined twice: explicit link to a from fragments[0], explicit link to b from fragments[1]" msg
    # the same target twice is still two sources
    &&
      merge.duplicateError [
        (at "a")
        (at "a")
      ] != null
  ))
  (check "links: a module's own merge is a fragment: its package links repeat without a clash" (
    let
      inner = merge [
        { packages = [ standIn ]; }
        { packages = [ openssh ]; }
      ];
      outer = compose [
        inner
        { packages = [ standIn ]; }
      ];
    in
    inner.links."/usr/bin/jq".kind == "package"
    && outer.links."/usr/bin/sshd".target == "${openssh}/bin/sshd"
    # /base adds more packages; check the requested ones are present
    && elem standIn outer.packages
    && elem openssh outer.packages
    # a package link to another target is still a clash
    && !(tryEval (
      deepSeq
        (compose [
          inner
          { packages = [ (withBin "jq-2" [ "jq" ]) ]; }
        ]).links
        true
    )).success
  ))
  (check "links: a farm and a dlopen link at one path clash across kinds" (
    let
      pkgA = withBin "a-1" [ ];
      pkgB = withBin "b-1" [ ];
      frags = [
        {
          packages = [ pkgA ];
          links."/usr/lib/security" = {
            target = "${pkgA}/lib/security";
            kind = "farm";
          };
        }
        {
          packages = [ pkgB ];
          links."/usr/lib/security" = {
            target = "${pkgB}/lib/security";
            kind = "dlopen";
          };
        }
      ];
      msg = merge.duplicateError frags;
    in
    !(tryEval (deepSeq (compose frags).links true)).success
    && hasInfix "farm link to /nix/store/a-1/lib/security from fragments[0], dlopen link to /nix/store/b-1/lib/security from fragments[1]" msg
  ))
  (check "links: the fixed sbin alias rejects every link kind" (
    builtins.all
      (
        kind:
        builtins.all
          (
            path:
            let
              frags = [
                {
                  links.${path} = {
                    target = "${standIn}/bin/jq";
                    inherit kind;
                  };
                }
              ];
              msg = merge.duplicateError frags;
            in
            !(tryEval (deepSeq (compose frags).links true)).success
            && msg != null
            && hasInfix path msg
            && hasInfix "/usr/bin" msg
          )
          [
            "/usr/sbin"
            "/usr/sbin/x"
          ]
      )
      [
        "explicit"
        "farm"
        "dlopen"
        "package"
      ]
  ))
  (check "links: distinct paths from every kind are no duplicate" (
    let
      tool = withBin "tool-1" [ "foo" ];
      frags = [
        {
          packages = [ tool ];
          links = {
            # use a path that doesn't conflict with /base
            "/usr/lib/custom/rules.d" = {
              target = "${tool}/lib/rules.d";
              kind = "farm";
            };
            "/usr/lib/libfoo.so.1" = {
              target = "${tool}/lib/libfoo.so.1";
              kind = "dlopen";
            };
          };
        }
        {
          links."/usr/lib/systemd/system/multi-user.target.wants/foo.service" = {
            target = "../foo.service";
            kind = "explicit";
          };
        }
      ];
      result = compose frags;
    in
    merge.duplicateError frags == null
    # /base adds links, check the fragment links are present
    && result.links ? "/usr/lib/custom/rules.d"
    && result.links ? "/usr/lib/libfoo.so.1"
    && result.links ? "/usr/bin/foo"
  ))
  (check "links: a link and a file at one path is an error" (
    let
      pkg = withBin "tool-1" [ ];
    in
    !(tryEval (
      deepSeq
        (compose [
          {
            packages = [ pkg ];
            links."/usr/lib/libfoo.so.1" = {
              target = "${pkg}/lib/libfoo.so.1";
              kind = "dlopen";
            };
          }
          { files."/usr/lib/libfoo.so.1" = "conflict"; }
        ]).links
        true
    )).success
  ))
  (check "links: farm and dlopen are not fragment fields (a farm or dlopen link is a links entry)" (
    !(tryEval (deepSeq (compose [ { farm."systemd-1" = [ "lib/udev/rules.d" ]; } ]).links true)).success
    && !(tryEval (deepSeq (compose [ { dlopen."tpm2-tss-1" = [ "libtss2-esys.so.0" ]; } ]).links true))
    .success
  ))
]
