#! The CA store of the image: one bundle, `/usr/share/ca-certificates/ca-bundle.crt`: Mozilla's roots plus `anchors`, minus `distrust`.
#! It is made when the image is built (`trust extract`, in the `ca-bundle` package), so it is read-only and no unit runs on the machine.
#! Tmpfiles link `/etc/ssl/cert.pem` and `/etc/ssl/certs/ca-certificates.crt` to it; an admin file at either path wins. A built-in component.
#! An `anchors` entry is one PEM certificate, a `distrust` entry the SHA-256 fingerprint of one (64 hex digits). A duplicate entry is an error.
#! Run-time anchors are not built, by design: a new release is the way (docs/design/trust.md, "CA store").
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
