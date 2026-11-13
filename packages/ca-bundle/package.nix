# ca-bundle: the image's one CA file, share/ca-certificates/ca-bundle.crt. /trust links it to
# /usr/share/ca-certificates/ca-bundle.crt, and tmpfiles make /etc/ssl/cert.pem (OpenSSL) and
# /etc/ssl/certs/ca-certificates.crt (curl) point at that (docs/design/trust.md, "3. CA store").
#
# Why extracted at build time: the image is immutable and /usr is verified by dm-verity, so the
# list of whom the machine trusts is signed with the release, and an update replaces it whole.
# Nothing on the machine writes or derives it: no unit, no writable bundle, no `trust` binary.
#
# What goes in: the roots of cacert (Mozilla's, server-auth only), plus the administrator's
# anchors, minus the distrusted certificates. The distrust list holds SHA-256 fingerprints of the
# DER form (modules/trust normalises them to 64 lower-case hex digits). p11-kit's trust module
# does the arithmetic: the roots and the anchors go into `anchors/`, each certificate whose
# fingerprint is listed (found among both) into `blocklist/`, and `trust extract` writes every
# anchor that is not blocklisted (a blocklisted certificate loses even when it is also an anchor).
# A listed fingerprint that matches no certificate of the roots or the anchors fails the build: a
# typo, or a root a cacert update dropped, must not pass in silence. The module is told the directory through a user module config
# (`x-init-reserved: paths=`) in the build directory, so the build reads no ambient path.
# The lists arrive as JSON in GOLCONDA_CA_ANCHORS (one PEM certificate per entry) and
# GOLCONDA_CA_DISTRUST (one fingerprint per entry); nix/packages.nix sets them from /trust's options (lib/system.nix), and they default
# to empty, which is cacert's roots as they are.
#
# The build checks the result itself, because `trust` skips a file it cannot parse without a
# word: the certificates of the bundle must be exactly (cacert's + anchors) - distrusted, as sets.
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
