# Checks of provenance data: explicit per option, declaredIn, inputs and the attribution of packages and files.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  binsFor,
  check,
  compose,
  f,
  fixturePkgs,
  merge,
  modulePaths,
  openssh,
  platform,
  schemaLib,
  sources,
  standIn,
  stubDash,
  stubSystemd,
  system,
  ...
}:
let
  inherit (builtins)
    attrNames
    filter
    length
    lessThan
    sort
    ;
in
[
  # package attribution
  (check "attribution: a package in two fragments lists both origins, in order" (
    let
      s2 = compose [
        { packages = [ standIn ]; }
        {
          name = "/services/x";
          packages = [ standIn ];
        }
        { packages = [ openssh ]; }
      ];
      o = s2.packageOrigins;
    in
    o.${merge.pkgKey standIn} == [
      "fragments[0]"
      "/services/x"
    ]
    && o.${merge.pkgKey openssh} == [ "fragments[2]" ]
    && length (filter (p: p == standIn) s2.packages) == 1
  ))
  (check "attribution: /base's systemd has origin /base; /network and sshd are named" (
    let
      o = (compose [ { packages = [ stubSystemd ]; } ]).packageOrigins;
      sshdO = system.packageOrigins;
    in
    o.${merge.pkgKey stubSystemd} == [
      "/base"
      "fragments[0]"
    ]
    && o.${merge.pkgKey stubDash} == [ "/base" ]
    && sshdO.${merge.pkgKey fixturePkgs.openssh} == [ "/services/sshd" ]
  ))
  (check "attribution: packageOrigins keys exactly the packages" (
    sort lessThan (attrNames system.packageOrigins) == sort lessThan (map merge.pkgKey system.packages)
  ))
  # Provenance data: explicit per option, declaredIn, inputs, attribution
  (check "provenance: config.json marks a TOML-set option explicit and a default not" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      cfg =
        (mkSystem {
          config = {
            "/system" = {
              name = "ui";
              version = "20261031.1";
            };
            "/services/sshd".authorizedKeys = [ "ssh-ed25519 AAAA" ];
          };
        }).config;
      sshd = cfg."/services/sshd";
    in
    sshd.authorizedKeys == {
      value = [ "ssh-ed25519 AAAA" ];
      explicit = true;
    }
    &&
      sshd.port == {
        value = 22;
        explicit = false;
      }
    # a computed default has no value; the TOML's own table is not hidden by the defaults
    && !(sshd.package ? value)
    && !sshd.package.explicit
    && cfg."/system".name.explicit
    &&
      cfg."/system".updateSource == {
        value = null;
        explicit = false;
      }
    # a value equal to the default is still explicit when the TOML says it
    && (mkSystem {
      config = {
        "/system" = {
          name = "ui";
          version = "20261031.1";
        };
        "/services/sshd".port = 22;
      };
    }).config."/services/sshd".port.explicit
  ))
  (check "provenance: schema declaredIn names the module and file of an option" (
    let
      sch = schemaLib.toJsonSchemaWith {
        files = modulePaths;
        root = toString ../../.;
      } (f.modules { });
      port = sch.properties."/services/sshd".properties.port;
    in
    port."x-golconda-declaredIn".module == "/services/sshd"
    && port."x-golconda-declaredIn".file == "modules/services/sshd/default.nix"
    && sch.properties."/system".properties.version."x-golconda-declaredIn".module == "/system"
  ))
  (check "provenance: schema inputs list the module paths a module reads" (
    let
      sch = schemaLib.toJsonSchema (f.modules { });
    in
    sch.properties."/services/sshd"."x-golconda-inputs" == [ "/pkgs" ]
    # the composer reads no module: mkSystem passes it the selected components
    && sch.properties."/system"."x-golconda-inputs" == [ ]
  ))
  (check "provenance: /base's links and units are attributed to /base" (
    let
      o = (compose [ ]).origins;
    in
    o.links."/usr/lib/systemd/system/dbus.service" == [ "/base" ]
    # /usr/bin/systemctl: the usr tree builder writes it into attribution.json with the
    # origins of its package (tests/usr-tree/builder.py)
    && map (b: b.origins) (binsFor [ ] stubSystemd) == [ [ "/base" ] ]
    && o.links."/usr/lib/systemd" == [ "/base" ]
    && o.files."/usr/lib/sysctl.d/50-golconda.conf" == [ "/security" ]
  ))
  (check "provenance: a listed fragment's file, unit, link and lines go to fragments[i] or its name" (
    let
      o =
        (compose [
          {
            files."/usr/lib/a/x" = "x";
            units."a.service" = "[Unit]\n";
            sysusers = [ "u a" ];
          }
          {
            name = "/services/b";
            files."/usr/lib/b/y" = "y";
            links."/usr/lib/b/z" = {
              target = "../a/x";
              kind = "explicit";
            };
            tmpfiles = [ "d /var/b" ];
          }
        ]).origins;
    in
    o.files."/usr/lib/a/x" == [ "fragments[0]" ]
    && o.units."a.service" == [ "fragments[0]" ]
    && o.sysusers."u a" == [ "fragments[0]" ]
    && o.files."/usr/lib/b/y" == [ "/services/b" ]
    && o.links."/usr/lib/b/z" == [ "/services/b" ]
    && o.tmpfiles."d /var/b" == [ "/services/b" ]
    # negative: nothing is attributed to a fragment that did not emit it
    && !(o.files ? "/usr/lib/nowhere")
    && o.packages == (compose [ ]).packageOrigins
    && system.packageOrigins == system.origins.packages
  ))
]
