#! The CA store of the image: whom the machine talks to over TLS.
#!
#! One bundle, `/usr/share/ca-certificates/ca-bundle.crt`: Mozilla's roots (cacert), plus the
#! administrator's `anchors`, minus the `distrust` list. It is made when the image is built
#! (`trust extract`, in the `ca-bundle` package), so it is read-only, covered by dm-verity and
#! replaced whole by an update; no unit runs on the machine and nothing writes it. A built-in
#! component: every system has it, and its table only configures it.
#!
#! Tmpfiles link the two paths the image's TLS clients read by default to that file:
#! `L /etc/ssl/cert.pem` (OpenSSL: `openssl version -d` says OPENSSLDIR=/etc/ssl) and
#! `L /etc/ssl/certs/ca-certificates.crt` (libcurl is built with CURL_CA_BUNDLE set to it). An
#! admin file at either path wins, as with every `L` line. No client reads another bundle.
#!
#! An entry of `anchors` is the text of one PEM certificate (public data, not a secret). An entry
#! of `distrust` is the SHA-256 fingerprint of a certificate's DER form: 64 hex digits, colons
#! between the bytes optional, any case. A certificate in both lists is distrusted. Distrusting a
#! Mozilla root removes it from the bundle; the other roots stay. A duplicate entry is an error
#! (a fingerprint is compared in its normal form). The build checks the result: the bundle holds
#! exactly the roots plus the anchors minus the distrusted ones, and a fingerprint that matches no
#! certificate of the roots or the anchors fails the build, so a typo does not pass.
#!
#! Leaf revocation is not covered: OpenSSL has no revocation list shared with other TLS stacks.
#! Run-time anchors (a unit that extracts from a directory in `/etc` or `/var`) are not built, by
#! design: a new release is the way; see `docs/design/trust.md`, "CA store".
{ types, ... }:
let
  inherit (builtins)
    attrNames
    filter
    length
    listToAttrs
    map
    match
    stringLength
    ;

  grammar = import ../lib/grammar.nix;

  # The largest entry. One certificate is a few KB; a bound keeps the regex below away from a
  # long value (std::regex recurses per character), and it is the schema's maxLength.
  maxPem = 16384;

  # One PEM certificate: the block, base64 only inside it, white space around it.
  pemCertificate = types.typedef' "pemCertificate" (
    v:
    if !builtins.isString v then
      "Expected the text of one PEM certificate, got ${builtins.typeOf v}"
    else if stringLength v > maxPem then
      "A certificate entry is at most ${toString maxPem} characters; this one has ${toString (stringLength v)}"
    else if match grammar.pemCertificate v == null then
      "Expected exactly one PEM certificate (-----BEGIN CERTIFICATE----- … -----END CERTIFICATE-----, base64 only, no comment or other block)"
    else
      null
  );

  # A SHA-256 fingerprint of a DER certificate, the way `openssl x509 -noout -fingerprint -sha256`
  # prints it (colons between the bytes) or as bare hex; either case. `fingerprint.normalise` is
  # the one form the build gets: 64 lower-case hex digits.
  sha256Fingerprint = types.typedef' "sha256Fingerprint" (
    v:
    if !builtins.isString v then
      "Expected a SHA-256 fingerprint (a string), got ${builtins.typeOf v}"
    else if match grammar.sha256Fingerprint v == null then
      "Expected a SHA-256 fingerprint of a certificate: 64 hex digits, or 32 pairs of hex digits separated by colons; got '${v}'"
    else
      null
  );
  inherit (import ../lib/fingerprint.nix) normalise;

  duplicates =
    xs:
    attrNames (
      listToAttrs (
        map (x: {
          name = x;
          value = null;
        }) (filter (x: length (filter (y: y == x) xs) > 1) xs)
      )
    );
in
{
  name = "trust";

  inputs.pkgs.path = "/pkgs";

  options = {
    anchors = {
      type = types.listOf pemCertificate;
      default = [ ];
      description = "Certificates to trust besides Mozilla's roots, each the text of one PEM certificate. They go into the bundle at build time.";
    };
    distrust = {
      type = types.listOf sha256Fingerprint;
      default = [ ];
      description = "Certificates to refuse, each the SHA-256 fingerprint of its DER form (64 hex digits, colons between the bytes optional, any case). The certificate is removed from the bundle, whether it is a Mozilla root or one of `anchors`. A fingerprint that matches no certificate fails the build.";
    };
  };

  impl =
    { options, results }:
    let
      p = results.pkgs.pkgs;
      bundle = "/usr/share/ca-certificates/ca-bundle.crt";
      dup = duplicates options.anchors ++ duplicates (map normalise options.distrust);
    in
    if dup != [ ] then
      throw "golconda: /trust lists the same certificate twice; a duplicate is an error, not a merge"
    else
      {
        # the bundle package is built from these options (lib/system.nix -> nix/packages.nix),
        # data only: the file is the one CA file of the image
        packages = [ p.ca-bundle ];

        links.${bundle} = {
          target = "${p.ca-bundle}/share/ca-certificates/ca-bundle.crt";
          kind = "explicit";
        };

        # /etc is created by tmpfiles at boot, and an admin file at either path wins (L, not L+).
        # OPENSSLDIR is /etc/ssl, so OpenSSL's default cert file is /etc/ssl/cert.pem; libcurl is
        # built with CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt.
        tmpfiles = [
          "L /etc/ssl/cert.pem - - - - ${bundle}"
          "L /etc/ssl/certs/ca-certificates.crt - - - - ${bundle}"
        ];
      };
}
