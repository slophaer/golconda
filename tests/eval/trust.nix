# Checks of /trust: the CA store of the image (docs/design/trust.md, "3. CA store"). The options
# `anchors` (PEM certificates) and `distrust` (SHA-256 fingerprints), the one bundle file in /usr and the paths that link it, and how the
# options reach the build of the ca-bundle package. What the build makes of them (the bundle's
# certificates) is checked by tests/real-packages/ca-store.nix.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  f,
  hasInfix,
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
    concatStringsSep
    deepSeq
    elem
    fromJSON
    genList
    match
    readFile
    stringLength
    substring
    tryEval
    ;
  fixture = n: readFile (../fixtures/ca-store + "/${n}");
  anchorCa = fixture "anchor-ca.crt";
  distrustedCa = fixture "distrusted-ca.crt";
  # the SHA-256 of each fixture's DER (tests/ca-store/check.py checks the file against the certificates)
  fp = fromJSON (fixture "fingerprints.json");
  distrustedFp = fp.distrusted-ca;
  mozillaFp = fp.mozilla-root;
  distrustType = (f.modules { }).modules.trust.options.distrust.type;
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
  fpSchema = schemaLib.typeRegistry.sha256Fingerprint;
  fpSchemaAccepts =
    x: match (whole fpSchema.pattern) x != null && stringLength x <= fpSchema.maxLength;

  # spellings of a fingerprint
  upper = builtins.replaceStrings lowerHex upperHex;
  lowerHex = [
    "a"
    "b"
    "c"
    "d"
    "e"
    "f"
  ];
  upperHex = [
    "A"
    "B"
    "C"
    "D"
    "E"
    "F"
  ];
  colons = h: concatStringsSep ":" (genList (i: substring (2 * i) 2 h) 32);
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
          distrustedFp
          (upper mozillaFp)
        ];
      });
    in
    fromJSON env.GOLCONDA_CA_ANCHORS == [
      anchorCa
      distrustedCa
    ]
    &&
      # one form for the build: lower case, no colons
      fromJSON env.GOLCONDA_CA_DISTRUST == [
        distrustedFp
        mozillaFp
      ]
  ))
  (check "trust: with no options the build gets two empty lists" (
    let
      env = envOf mkSystemFixture;
    in
    fromJSON env.GOLCONDA_CA_ANCHORS == [ ] && fromJSON env.GOLCONDA_CA_DISTRUST == [ ]
  ))
  (check "trust: an anchor is one PEM certificate, a distrusted one a SHA-256 fingerprint" (
    accepts { anchors = [ anchorCa ]; }
    && accepts { distrust = [ mozillaFp ]; }
    # the same certificate in both lists is allowed: distrust wins
    && accepts {
      anchors = [ distrustedCa ];
      distrust = [ distrustedFp ];
    }
    # whitespace around the block is fine
    && accepts { anchors = [ "\n${anchorCa}\n\n" ]; }
  ))
  (check "trust: an entry that is not exactly one PEM certificate is refused" (
    let
      key = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIA==\n-----END PRIVATE KEY-----\n";
      refused = x: !(accepts { anchors = [ x ]; });
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
    # a fingerprint is not a certificate
    && refused mozillaFp
    # one block is a few KB; a value far past that is refused before the regex reads it
    && refused (
      "-----BEGIN CERTIFICATE-----\n"
      + builtins.concatStringsSep "" (
        builtins.genList (_: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n") 400
      )
      + "-----END CERTIFICATE-----\n"
    )
  ))
  (check "trust: a distrust entry is 64 hex digits, colons between the bytes optional, any case" (
    accepts { distrust = [ mozillaFp ]; }
    && accepts { distrust = [ (upper mozillaFp) ]; }
    && accepts { distrust = [ (colons mozillaFp) ]; }
    && accepts { distrust = [ (colons (upper mozillaFp)) ]; }
  ))
  (check
    "trust: a distrust entry that is not a SHA-256 fingerprint is refused, with a message that says so"
    (
      let
        bad = [
          ""
          "not a fingerprint"
          (substring 1 63 mozillaFp)
          (mozillaFp + "0")
          # SHA-1 and SHA-512 lengths
          (substring 0 40 mozillaFp)
          (mozillaFp + mozillaFp)
          # not hex
          ("g" + substring 1 63 mozillaFp)
          # colons in the wrong places, or only some
          (":" + colons mozillaFp)
          (colons mozillaFp + ":")
          (substring 0 10 mozillaFp + ":" + substring 10 54 mozillaFp)
          (substring 0 2 mozillaFp + "::" + substring 2 62 mozillaFp)
          # a prefix, white space, another separator
          "sha256:${mozillaFp}"
          " ${mozillaFp}"
          "${mozillaFp}\n"
          (builtins.replaceStrings [ ":" ] [ " " ] (colons mozillaFp))
          # the certificate itself is no fingerprint
          distrustedCa
        ];
        msg = x: distrustType.verify [ x ];
      in
      all (x: !(accepts { distrust = [ x ]; })) bad
      && all (x: msg x != null && hasInfix "SHA-256 fingerprint" (msg x)) bad
      && distrustType.verify [ mozillaFp ] == null
      && !(accepts { distrust = [ 7 ]; })
    )
  )
  (check "trust: the same fingerprint twice is a duplicate, whatever its spelling" (
    throws
      (sysWith {
        distrust = [
          mozillaFp
          (colons (upper mozillaFp))
        ];
      }).composed.links
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
            mozillaFp
            mozillaFp
          ];
        }).composed.links
  ))
  (check "trust: the schema pattern and the type agree on the samples" (
    all (x: schemaAccepts x == accepts { anchors = [ x ]; }) [
      anchorCa
      distrustedCa
      "\n${anchorCa}\n"
      ""
      "not a certificate"
      (anchorCa + distrustedCa)
      "-----BEGIN CERTIFICATE-----\nAAAA!AAAA\n-----END CERTIFICATE-----\n"
      "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
    ]
    && pemSchema.description != ""
    && all (x: fpSchemaAccepts x == accepts { distrust = [ x ]; }) [
      mozillaFp
      (upper mozillaFp)
      (colons mozillaFp)
      (substring 1 63 mozillaFp)
      (mozillaFp + "0")
      (":" + colons mozillaFp)
      "sha256:${mozillaFp}"
      distrustedCa
      ""
    ]
    && fpSchema.description != ""
  ))
  (check "trust: ca-bundle is a package of /trust, not of /base" (
    (mkSystemFixture.composed.origins.packages.ca-bundle or [ ]) == [ "/trust" ]
  ))
]
