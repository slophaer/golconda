# Test keys of the stub OIDC provider in ../oidc.rs (P-256, PKCS8). Not secrets: they sign

# tokens only inside the tests. oidc-other signs the tokens that must be refused.

# tls-ca.pem is a test CA (its key is not kept) that signed tls-server.pem for 127.0.0.1, with

# tls-server.key: the stub provider over https, which the daemon trusts only with --oidc-ca-file.

# oidc-extra.jwk.json is a public key only, a second EC key in the stub's set, so that a token

# without kid has more than one key to try.
