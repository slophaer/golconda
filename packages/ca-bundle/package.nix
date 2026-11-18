# ca-bundle: the image's one CA file, share/ca-certificates/ca-bundle.crt. /trust links it to
# /usr/share/ca-certificates/ca-bundle.crt, and tmpfiles make /etc/ssl/cert.pem (OpenSSL) and
# /etc/ssl/certs/ca-certificates.crt (curl) point at that (docs/design/trust.md, "3. CA store").
#
# Made from cacert's roots (server-auth) when the image is built, plus the anchors, minus the
# distrusted fingerprints; p11-kit's trust module does the arithmetic, and the build checks the
# result as sets, because `trust` skips a file it cannot parse in silence (docs/design/ca-store.md).
# The lists arrive as JSON in GOLCONDA_CA_ANCHORS (PEM certificates) and GOLCONDA_CA_DISTRUST
# (fingerprints); /trust sets them from its options in a variant of this package. The trust module reads its
# directory from a module config in the build directory (`x-init-reserved: paths=`), no ambient
# path. No sources.toml: the source is cacert's directory (sourceOf).
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "ca-bundle";
  inherit (pkgs.cacert) version;
  source = "${pkgs.cacert}/etc/ssl/certs";
  sourceOf = {
    package = pkgs.cacert;
    subpath = "certifi/cacert.pem";
  };
  buildDependencies = [ buildPkgs.p11-kit ]; # trust, and its module
  env = {
    GOLCONDA_CA_ANCHORS = "[]";
    GOLCONDA_CA_DISTRUST = "[]";
    # the trust module the build host runs (a store path, so it is an input)
    GOLCONDA_CA_TRUST_MODULE = "${buildPkgs.p11-kit}/lib/pkcs11/p11-kit-trust.so";
  };
  phases = [
    {
      name = "install";
      run = (builtins.readFile ./select.nu) + ''
        let c = (ctx)
        let work = $"($env.TMPDIR? | default /tmp)/ca-store"
        let anchors = $"($work)/trust/anchors"
        let blocklist = $"($work)/trust/blocklist"
        let config = $"($work)/config"
        for d in [$anchors $blocklist $"($config)/pkcs11/modules" $"($work)/home"] { mkdir $d }

        let roots = (open --raw $"($c.src)/ca-bundle.crt")
        let admin = ($env.GOLCONDA_CA_ANCHORS | from json)
        let distrust = ($env.GOLCONDA_CA_DISTRUST | from json)
        let sel = (ca-select $roots $admin $distrust)
        $roots | save $"($anchors)/mozilla.pem"
        for e in ($admin | enumerate) { $e.item | save $"($anchors)/admin-($e.index).pem" }

        for e in ($sel.denied | enumerate) {
          $"-----BEGIN CERTIFICATE-----\n($e.item)\n-----END CERTIFICATE-----\n" | save $"($blocklist)/distrust-($e.index).pem"
        }

        $"module: ($env.GOLCONDA_CA_TRUST_MODULE)\ntrust-policy: yes\nx-init-reserved: paths=($work)/trust\n"
        | save $"($config)/pkcs11/modules/trust.module"
        "user-config: only\n" | save $"($config)/pkcs11/pkcs11.conf"

        let bundle = $"($work)/ca-bundle.crt"
        with-env {HOME: $"($work)/home", XDG_CONFIG_HOME: $config} {
          ^trust extract --format=pem-bundle --filter=ca-anchors --purpose=server-auth $bundle
        }

        let want = $sel.want
        let got = (ca-blocks (open --raw $bundle))
        let missing = ($want | where {|b| not ($b in $got) })
        let extra = ($got | where {|b| not ($b in $want) })
        if ($missing | is-not-empty) or ($extra | is-not-empty) or (($got | length) != ($got | uniq | length)) {
          error make {msg: $"ca-bundle: trust extract wrote ($got | length) certificates; expected ($want | length), missing ($missing | length), unexpected ($extra | length)"}
        }

        mkdir $"($c.out)/share/ca-certificates"
        ^cp $bundle $"($c.out)/share/ca-certificates/ca-bundle.crt"
      '';
    }
  ];
  # data only: no libraries, no programs
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
  bin = [ ];
  tests.version = false;
  platforms.os = [ "linux" ];
}
