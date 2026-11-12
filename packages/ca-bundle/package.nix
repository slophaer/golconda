# ca-bundle: the image's one CA file, share/ca-certificates/ca-bundle.crt. /trust links it to
# /usr/share/ca-certificates/ca-bundle.crt, and tmpfiles make /etc/ssl/cert.pem (OpenSSL) and
# /etc/ssl/certs/ca-certificates.crt (curl) point at that (docs/design/trust.md, "3. CA store").
#
# Why extracted at build time: the image is immutable and /usr is verified by dm-verity, so the
# list of whom the machine trusts is signed with the release, and an update replaces it whole.
# Nothing on the machine writes or derives it: no unit, no writable bundle, no `trust` binary.
#
# What goes in: the roots of cacert (Mozilla's, server-auth only), plus the administrator's
# anchors, minus the distrusted certificates. p11-kit's trust module does the arithmetic: the
# roots and the anchors go into `anchors/`, the distrusted certificates into `blocklist/`, and
# `trust extract` writes every anchor that is not blocklisted (a blocklisted certificate loses
# even when it is also an anchor). The module is told the directory through a user module config
# (`x-init-reserved: paths=`) in the build directory, so the build reads no ambient path.
# The lists arrive as JSON in GOLCONDA_CA_ANCHORS and GOLCONDA_CA_DISTRUST, one PEM certificate
# per entry; nix/packages.nix sets them from /trust's options (lib/system.nix), and they default
# to empty, which is cacert's roots as they are.
#
# The build checks the result itself, because `trust` skips a file it cannot parse without a
# word: the certificates of the bundle must be exactly (cacert's + anchors) - distrust, as sets.
# A package that fails here fails the image build, not the boot.
#
# The source is cacert's directory, so there is no second pin to keep in step: a cacert update
# updates this. No sources.toml; the SBOM purl is cacert's plus a subpath (lib/sbom-sources.nix).
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "ca-bundle";
  inherit (pkgs.cacert) version;
  source = "${pkgs.cacert}/etc/ssl/certs";
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
      run = ''
        let c = (ctx)
        let work = $"($env.TMPDIR? | default /tmp)/ca-store"
        let anchors = $"($work)/trust/anchors"
        let blocklist = $"($work)/trust/blocklist"
        let config = $"($work)/config"
        for d in [$anchors $blocklist $"($config)/pkcs11/modules" $"($work)/home"] { mkdir $d }

        # PEM text -> the base64 of each certificate block, whitespace removed
        let blocks = {|text|
          $text
          | parse --regex '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----'
          | get capture0
          | each {|b| $b | str replace --all --regex '\s+' "" }
        }

        let roots = (open --raw $"($c.src)/ca-bundle.crt")
        let admin = ($env.GOLCONDA_CA_ANCHORS | from json)
        let distrust = ($env.GOLCONDA_CA_DISTRUST | from json)
        for l in [[anchors $admin] [distrust $distrust]] {
          for e in $l.1 {
            if (do $blocks $e | length) != 1 {
              error make {msg: $"ca-bundle: a ($l.0) entry is not exactly one PEM certificate"}
            }
          }
        }
        $roots | save $"($anchors)/mozilla.pem"
        for e in ($admin | enumerate) { $e.item | save $"($anchors)/admin-($e.index).pem" }
        for e in ($distrust | enumerate) { $e.item | save $"($blocklist)/distrust-($e.index).pem" }

        $"module: ($env.GOLCONDA_CA_TRUST_MODULE)\ntrust-policy: yes\nx-init-reserved: paths=($work)/trust\n"
        | save $"($config)/pkcs11/modules/trust.module"
        "user-config: only\n" | save $"($config)/pkcs11/pkcs11.conf"

        let bundle = $"($work)/ca-bundle.crt"
        with-env {HOME: $"($work)/home", XDG_CONFIG_HOME: $config} {
          ^trust extract --format=pem-bundle --filter=ca-anchors --purpose=server-auth $bundle
        }

        let denied = ($distrust | each {|e| do $blocks $e } | flatten)
        let want = ((do $blocks $roots) ++ ($admin | each {|e| do $blocks $e } | flatten)
          | where {|b| not ($b in $denied) }
          | uniq)
        let got = (do $blocks (open --raw $bundle))
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
