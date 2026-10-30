# Trust

*(Planned.)* This page describes the target trust model. Secure Boot, measured boot and TPM2
credential decryption are not implemented.

There are three trust roots on a Golconda machine. Each is one key hierarchy, and nothing ships its
own copy of any of them:

1. **Secure Boot and measured boot keys** decide *what runs*: the Secure Boot `db` key signs
   systemd-boot and every UKI; the PCR policy key signs the expected PCR 11 values and is what
   TPM2-sealed credentials are bound to.
1. **The verity signing key** decides *what is read*: it signs the root hash of every `/usr` image.
1. **The CA store** decides *whom the machine talks to*: one set of anchors for every TLS client.

### 1. Boot keys

```mermaid
flowchart LR
  db["Secure Boot db key"] --> sdboot[systemd-boot]
  db --> uki["UKI (kernel, initrd, cmdline)"]
  pcr["PCR policy key"] --> pcrsig[".pcrsig inside the UKI"]
  pcrsig --> tpm["TPM2: PCR 11 policy"]
  tpm --> creds["sealed credentials (LoadCredentialEncrypted=)"]
  tpm -.->|later| luks["state partition LUKS2 unlock"]
```

### 2. Verity key

```mermaid
flowchart LR
  vk["verity signing key"] --> vsig["usr-verity-sig partition (PKCS#7 of the root hash)"]
  cert["verity certificate, carried in the signed UKI"] --> keyring["kernel .platform keyring"]
  vsig --> veritysetup[systemd-veritysetup]
  keyring --> veritysetup
  veritysetup --> usr["/usr read-only, verified per block"]
```

### 3. CA store

```mermaid
flowchart LR
  anchors["/etc/ssl/anchors/*.pem (factory: Mozilla roots + admin anchors)"] --> trust["p11-kit trust extract"]
  block["/etc/ssl/blocklist/ (distrust)"] --> trust
  trust --> bundle["/etc/ssl/certs: bundle + hashed dir"]
  bundle --> consumers["OpenSSL (OPENSSLDIR=/etc/ssl); Go, rustls, Python via SSL_CERT_FILE"]
```

## One CA store

The source of truth is `/etc/ssl` as a p11-kit trust path: anchors in `/etc/ssl/anchors/*.pem` (the
Mozilla roots from the image plus administrator anchors) and distrust entries in
`/etc/ssl/blocklist/`. `p11-kit trust extract` derives from them the OpenSSL bundle and hashed
directory and honours the blocklist, which is the only root-level revocation that works across TLS
stacks. There is no Java in the image, so no keystore is generated. Every consumer points at the
same bundle: OpenSSL by `OPENSSLDIR=/etc/ssl`, everything else by `SSL_CERT_FILE` in systemd's
default environment. No package ships `certifi` or its own bundle.

Leaf revocation is not unified: OpenSSL, rustls and Go do not share a mechanism. Golconda's own PKI
uses short-lived certificates instead.

## Verity and the kernel keyring

The `usr-verity-sig` partition holds a PKCS#7 signature of the root hash. systemd-veritysetup asks
the kernel to check it against the keys in the `.platform` or `.machine` keyring, so the verity
signing certificate is part of the UKI's signed payload.

## TPM2 credential decryption

UKIs are signed with `ukify --phases=enter-initrd:leave-initrd:sysinit:ready`. This lets TPM2-sealed
credentials unseal both in the initrd (for LUKS unlock) and at service time.

### Rollback weakness

Any image signed by the same PCR 11 key unseals credentials sealed for that key. An attacker who
obtains an older, vulnerable image can boot it and decrypt secrets.

Mitigations:

- **pcrlock** (systemd 256+): binds to the exact PCR values of one image. A rollback fails because
  the old image's PCRs do not match.
- **Key rotation:** re-seal credentials with a new key pair after a security-critical update.
- **policyref** (systemd 262+): embeds a reference so the TPM refuses policies signed for a
  different reference.
- **TPM NV monotonic counter:** a future mechanism; no comparable project implements it yet.

## Secrets and vars

Secrets never enter the image or the store. Services receive them with `LoadCredential=` and
`LoadCredentialEncrypted=` (`systemd-creds`, TPM2-bound, sealed with the PCR 11 signing key).

A **var** is a generator that produces credentials. The image declares vars; the machine or the
deploy host generates them. Values are never read at evaluation time.

Three classes:

- **Machine-local.** Generated on the machine at first boot (ssh host keys, wireguard keys). The
  generator runs in a oneshot unit, seals the result with `systemd-creds encrypt`, and exports only
  the public half.
- **Admin-supplied.** Kept age-encrypted on the deploy host, pushed over ssh, sealed on the machine.
  Covers root password hashes and admin credentials.
- **Bootstrap.** A few ESP or SMBIOS credentials plus `systemd-firstboot` (`firstboot.hostname`,
  `passwd.hashed-password.root`). Never put real secrets in a null-key credential: the ESP is not
  encrypted.

See [reference/vars](../reference/modules/vars.md) for the `var` helper. *(planned)*
