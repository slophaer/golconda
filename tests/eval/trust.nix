# Checks of /trust: the CA store of the image (docs/design/trust.md, "3. CA store"). The options
# `anchors` and `distrust`, the one bundle file in /usr and the paths that link it, and how the
# options reach the build of the ca-bundle package. What the build makes of them (the bundle's
# certificates) is checked by tests/real-packages/ca-store.nix.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  hasPrefix,
  mkSystemFixture,
  platform,
  schemaLib,
  sources,
  stubCaBundle,
  ...
}:
let
  inherit (builtins)
    all
    deepSeq
    elem
    fromJSON
    match
    readFile
    stringLength
    substring
    tryEval
    ;
  fixture = n: readFile (../fixtures/ca-store + "/${n}");
  anchorCa = fixture "anchor-ca.crt";
  distrustedCa = fixture "distrusted-ca.crt";
  mozillaRoot = fixture "mozilla-root.crt";
  bundle = "/usr/share/ca-certificates/ca-bundle.crt";

  sysWith =
    trust:
    import ../../lib/system.nix {
      inherit sources platform;
      system = platform;
      config = {
        "/system" = {
          name = "test";
          version = "20261031.1";
        };
        "/trust" = trust;
      };
    };
  throws = x: !(tryEval (deepSeq x x)).success;
  # the options are checked when the composer reads them
  accepts = trust: (tryEval (deepSeq (sysWith trust).composed.links true)).success;
  envOf = sys: sys.pkgs.ca-bundle.spec.env;

  # the pattern as the schema exports it, read as builtins.match reads it
  pemSchema = schemaLib.typeRegistry.pemCertificate;
  whole = p: substring 1 (stringLength p - 2) p;
  schemaAccepts =
    x: match (whole pemSchema.pattern) x != null && stringLength x <= pemSchema.maxLength;
in
[
  (check "trust: /trust is a built-in component, with no anchors and no distrust by default" (
    mkSystemFixture.inventory."/trust".reason == "builtin"
    &&
      mkSystemFixture.config."/trust".anchors == {
        value = [ ];
        explicit = false;
      }
    &&
      mkSystemFixture.config."/trust".distrust == {
        value = [ ];
        explicit = false;
      }
  ))
  (check
    "trust: the one CA bundle is the ca-bundle package's, linked from the paths OpenSSL and curl read"
    (
      let
        result = compose [ ];
      in
      result.links."${bundle}" == {
        target = "${stubCaBundle}/share/ca-certificates/ca-bundle.crt";
        kind = "explicit";
      }
      && (result.origins.links."${bundle}" or [ ]) == [ "/trust" ]
      # OPENSSLDIR=/etc/ssl (openssl version -d): the default cert file
      && elem "L /etc/ssl/cert.pem - - - - ${bundle}" result.tmpfiles
      # curl's compiled-in CURL_CA_BUNDLE, and the directory it and OpenSSL search as well
      && elem "L /etc/ssl/certs/ca-certificates.crt - - - - ${bundle}" result.tmpfiles
    )
  )
  (check "trust: the image has no second CA file: cacert is a build input of ca-bundle, not a package"
    (
      let
        result = compose [ ];
        has = prefix: builtins.any (p: hasPrefix prefix p.name) result.packages;
      in
      has "ca-bundle-" && !(has "cacert-")
    )
  )
  (check "trust: the factory seeds no ssl/anchors or ssl/blocklist: nothing on the machine reads them"
    (
      let
        inherit (compose [ ]) files;
      in
      all (p: !(files ? "/usr/share/factory/etc/${p}")) [
        "ssl/anchors/.keep"
        "ssl/blocklist/.keep"
      ]
    )
  )
  (check "trust: the options reach the ca-bundle build as JSON, in order" (
    let
      env = envOf (sysWith {
        anchors = [
          anchorCa
          distrustedCa
        ];
        distrust = [
          distrustedCa
          mozillaRoot
        ];
      });
    in
    fromJSON env.GOLCONDA_CA_ANCHORS == [
      anchorCa
      distrustedCa
    ]
    &&
      fromJSON env.GOLCONDA_CA_DISTRUST == [
        distrustedCa
        mozillaRoot
      ]
  ))
  (check "trust: with no options the build gets two empty lists" (
    let
      env = envOf mkSystemFixture;
    in
    fromJSON env.GOLCONDA_CA_ANCHORS == [ ] && fromJSON env.GOLCONDA_CA_DISTRUST == [ ]
  ))
  (check "trust: an anchor and a distrusted certificate are each one PEM certificate" (
    accepts { anchors = [ anchorCa ]; }
    && accepts { distrust = [ mozillaRoot ]; }
    # the same certificate in both lists is allowed: distrust wins
    && accepts {
      anchors = [ distrustedCa ];
      distrust = [ distrustedCa ];
    }
    # whitespace around the block is fine
    && accepts { anchors = [ "\n${anchorCa}\n\n" ]; }
  ))
  (check "trust: an entry that is not exactly one PEM certificate is refused" (
    let
      key = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIA==\n-----END PRIVATE KEY-----\n";
      refused = x: !(accepts { anchors = [ x ]; }) && !(accepts { distrust = [ x ]; });
    in
    refused ""
    && refused "not a certificate"
    && refused key
    && refused (anchorCa + distrustedCa)
    && refused (anchorCa + "trailing text")
    && refused "# comment\n${anchorCa}"
    && refused "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n"
    && refused "-----BEGIN CERTIFICATE-----\nAAAA!AAAA\n-----END CERTIFICATE-----\n"
    && refused "/etc/ssl/anchors/corp.pem"
    # one block is a few KB; a value far past that is refused before the regex reads it
    && refused (
      "-----BEGIN CERTIFICATE-----\n"
      + builtins.concatStringsSep "" (
        builtins.genList (_: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n") 400
      )
      + "-----END CERTIFICATE-----\n"
    )
  ))
  (check "trust: a duplicate anchor or a duplicate distrust entry is an error, not a merge" (
    throws
      (sysWith {
        anchors = [
          anchorCa
          anchorCa
        ];
      }).composed.links
    &&
      throws
        (sysWith {
          distrust = [
            mozillaRoot
            mozillaRoot
          ];
        }).composed.links
  ))
  (check "trust: the schema pattern and the type agree on the samples" (
    all (x: schemaAccepts x == accepts { anchors = [ x ]; }) [
      anchorCa
      distrustedCa
      mozillaRoot
      "\n${anchorCa}\n"
      ""
      "not a certificate"
      (anchorCa + distrustedCa)
      "-----BEGIN CERTIFICATE-----\nAAAA!AAAA\n-----END CERTIFICATE-----\n"
      "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
    ]
    && pemSchema.description != ""
  ))
  (check "trust: ca-bundle is a package of /trust, not of /base" (
    (mkSystemFixture.composed.origins.packages.ca-bundle or [ ]) == [ "/trust" ]
  ))
]
