# Secrets as vars

A var is a value that the image names but never contains. No secret enters the image or the Nix
store, and no build step reads one. The machine makes or receives each secret. It seals the secret
to its own TPM2 (a security chip) and hands it to one service as a systemd credential.

## How it works

There are two classes of var.

- **local**: the machine generates the value at first boot. `golconda-var-<name>.service` runs
  `/usr/lib/golconda/golconda-var-run`, which runs the generator script, seals each secret with
  `systemd-creds encrypt --with-key=auto --tpm2-public-key-pcrs=11`, and keeps only the public
  files. With a TPM2, the credential is bound to that TPM and to the image's PCR 11 signing key.
  (PCR 11 is a TPM register that holds the measurement of the boot image.) Without a TPM2, it is
  bound to the host key only.

  The seal names the key that signs the PCR 11 values, not the values themselves. So the next
  release unseals without re-sealing, as long as it is signed with the same PCR key, and so does the
  previous release after a fallback. The same property lets an attacker boot an older signed image
  and unseal ([Limits](#limits)). A release signed with a new PCR key cannot unseal what the old key
  sealed, which is why a `db` rotation keeps the PCR key (`pcrKeys`).
  `hostkey-unsealed-after-update` shows the next release unsealing the host key.

- **admin**: the deploy host keeps the value encrypted with age (a file-encryption tool), pushes it
  over ssh, and the machine seals it with its own `systemd-creds`. The image carries only the
  manifest entry, and no unit. The consumer's unit waits for the push.

Both classes end the same way. The sealed file is
`/var/lib/golconda/credstore.encrypted/<name>.<file>`. A service names the credential id
`<name>.<file>`, and the unit gets
`LoadCredentialEncrypted=<id>:/var/lib/golconda/credstore.encrypted/<id>`. The path is absolute:
`/etc` is read-only, and systemd searches no credstore under `/var`. The program reads the value
from its credentials directory: in `app.argv`, a typed reference renders as `%d/<id>`. No path to a
secret appears in the image.

The image lists every var in `/usr/lib/golconda/vars.d/<name>.json`: name, class, files and
credential ids. A local var also has `<name>.sh`, its generator script.

Local vars run once. The runner writes `/var/lib/golconda/vars/<name>/done` last, and the unit has
`ConditionPathExists=!` on that marker. It puts public files in `/var/lib/golconda/vars/<name>/pub/`
and removes the plaintext from the runtime directory.

**Rotation.** To rotate an admin var, push a new value. The consumer restarts and reads the new
sealed credential. To rotate a local var, remove its `done` marker and reboot.

## Using it

The image has one local var, the sshd host key. This is its code, from `modules/services/sshd`:

```nix
v.render {
  name = "sshd-hostkey";
  secrets = [ "key" ];
  publics = [ "key.pub" ];
  script = "ssh-keygen -q -t ed25519 -N '' -f key";
  packages = [ options.package ];
}
```

The consumer names the credential and orders itself after the var:

```nix
credentials.hostkey = v.credentialId "sshd-hostkey" "key";  # sshd-hostkey.key
after = [ (v.unitName "sshd-hostkey") ];
```

For an admin var, write one call: `v.admin { name = "sshd-host-cert"; files = [ "cert" ]; }`.

## Status

The boot test proves the sshd host key. With `--ssh-test --tpm` it checks four markers, and a fifth
with `--next`:

- `var-sshd-hostkey`: the unit finished.
- `hostkey-sealed-with-tpm2`: the credential header says host key, TPM2 and signed PCR policy.
- `ssh-after-reboot` and `hostkey-unchanged`: the key unsealed after a reboot and was not made
  again.
- `hostkey-unsealed-after-update`: the next release presents the same host key.

See [What is proven](../proven.md).

The on-machine side of admin vars exists: the manifest, the credential ids and the consumer in sshd.
The deploy tool that pushes and seals them is *(planned)*. No boot test covers an admin var.

## Limits

- **Rollback.** Any image signed with the same PCR 11 key unseals the credentials. Someone with an
  older, vulnerable image can boot it and read the secrets. The fixes are *(after v1)*: pcrlock, key
  rotation, policyref, a TPM counter.
- **One secret.** The sshd host key is the only sealed secret. The state partition is not encrypted
  in v1.
- **TPM loss.** A sealed credential dies with its TPM. That is why admin values live on the deploy
  host.
- Without a TPM2, a local var seals to the host key only.
- **A stable machine id.** The host secret of `systemd-creds` is bound to the machine id. PID 1
  takes it from the `system.machine_id` credential or the SMBIOS UUID. A board with no UUID, or with
  one that is not unique, needs the credential
  ([Layout: The read-only /etc](../design/layout.md#the-read-only-etc)).
- Bootstrap values such as the host name are not vars. They are plain credentials, and they carry no
  secret ([Provisioning](provisioning.md)).

## More

- [Trust: Secrets and vars](../design/trust.md#secrets-and-vars)
- [Trust: TPM2 credential decryption](../design/trust.md#tpm2-credential-decryption) and
  [Rollback weakness](../design/trust.md#rollback-weakness)
- [Reference: modules, var names](../reference/modules/README.md#var-names)
- [Measured boot](measured-boot.md), [Certificate login](ssh-login.md)
