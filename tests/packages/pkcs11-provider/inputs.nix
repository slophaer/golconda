# the token the provider signs through (softhsm, test-only), and openssl that loads it
pkgs: { inherit (pkgs) openssl softhsm; }
