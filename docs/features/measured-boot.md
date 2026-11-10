# Secure Boot and measured boot

Firmware starts only code that your key signed. The TPM2 (a security chip) then records what booted,
and a secret opens only for a boot you signed. Golconda signs the loader, the kernel image and the
policy with keys you make, so a swapped kernel opens nothing.

## How it works

- **Signed boot.** The `db` key signs systemd-boot (`lib/image/loader.nu`) and each UKI (unified
  kernel image, `lib/image/uki.nu`). Firmware checks both against its `db`. With only your
  certificate enrolled, it refuses an unsigned loader.
- **PCR 11.** systemd-stub measures the UKI's parts into PCR 11, a TPM2 register. At build time
  `systemd-measure` computes the expected values and signs them with the PCR key. The signatures
  travel in the UKI as `.pcrsig`. The public key is `.pcrpkey`.
- **Four phases.** The UKI signs four boot states: `enter-initrd`, `enter-initrd:leave-initrd`,
  `enter-initrd:leave-initrd:sysinit` and `enter-initrd:leave-initrd:sysinit:ready`. sshd starts at
  `sysinit`. A single signature at `ready` would leave sshd with nothing it may unseal. The build
  recomputes each digest and fails if one is missing.
- **Sealing.** `golconda-var-sshd-hostkey.service` runs
  `systemd-creds encrypt --with-key=auto --tpm2-public-key-pcrs=11`. sshd loads the result with
  `LoadCredentialEncrypted=`. The key is sealed to the PCR key, not to one PCR value, so a new
  signed image unseals it with no re-enrolment.
- **Deployment keys.** `scripts/make-keys` writes `secureboot/db.{key,crt}`, `pcr/pcr.{key,pub}` and
  the release key. The image chain needs no `PK` or `KEK`. The private keys never enter the image.
- **Without Secure Boot.** With `/system.secureBoot = false`, the kernel carries the `db`
  certificate itself (`CONFIG_SYSTEM_TRUSTED_KEYS`, a fixed path the build fills) and checks the
  `/usr` signature. Each key set builds its own kernel, with the same config, so with jig's compile
  cache only two objects compile again. Vars seal to the host key alone, with no TPM.

## Using it

```sh
scripts/make-keys /srv/golconda-keys
```

```sh
golconda release build -f server.toml --keys /srv/golconda-keys
```

Then enrol `secureboot/db.crt` in the firmware. For a host with no Secure Boot, such as Hetzner
Cloud:

```toml
["/system"]
secureBoot = false
```

A signed release (`golconda release build`, or `lib.mkImage` and its signer) is required for that
mode. The procedure is in [Making a release](../reference/release.md) and the
[Hetzner page](../reference/hetzner-cloud.md).

## Status

Proven in QEMU with OVMF: `secure-boot-enabled`, and after a key rotation `old-loader-refused` (a
loader signed with a key now in `dbx`). No marker boots an unsigned loader.
`hostkey-sealed-with-tpm2`, `ssh-after-reboot` and `hostkey-unchanged` (`--tpm`) show the seal and
the unseal, also after an update and after a fallback (`--tpm --next`, with `--fail-health`).
`boots-after-rotation` and `old-loader-refused` cover a `db` rotation. A deployment key set made by
`scripts/make-keys` booted on the same markers. The no-Secure-Boot image (`image-smoke-test-nosb`)
boots and updates. See [What is proven](../proven.md).

## Limits

- Enrolment is manual (`virt-fw-vars`, `sbctl` or firmware setup). Automatic enrolment is *(later)*.
  The harness enrols offline, so real firmware has not run. Hetzner Cloud ran without Secure Boot
  and without a TPM ([What is proven](../proven.md#on-hetzner-cloud)).
- Only the sshd host key is sealed. The state partition is not (LUKS2 is *(later)*).
- Without Secure Boot, nothing checks the UKI before it runs. Whoever can write the ESP can boot a
  kernel that trusts another key. IPE and the `/usr` signature still hold.
- An older image signed by the same PCR key can unseal. Pcrlock, policyref and key rotation are
  *(later)*.
- Rotating the PCR key is not covered. Loader recovery by hand has no marker.

## More

- [Trust: boot keys](../design/trust.md#1-boot-keys),
  [deployment keys](../design/trust.md#deployment-keys) and
  [TPM2 credential decryption](../design/trust.md#tpm2-credential-decryption)
- [Boot: measured boot](../design/boot.md#measured-boot) and
  [Secure Boot](../design/boot.md#secure-boot)
- [Boot loader: key rotation](../design/bootloader.md#key-rotation)
- [Only signed code runs](execution-policy.md) and [Vars](vars.md)
