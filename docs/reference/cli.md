# Commands

The commands a developer and a release run. Most are `nix-build` and `iets` invocations or scripts
in `scripts/`; the `golconda` command line has two commands, `vars` and `release`.

| command                                                                                                   | does                                                                                                                                                        |
| --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix-build -A packages.<system>.<name>`                                                                   | build one package or `/usr` tree                                                                                                                            |
| `nix-build -E '(import ./examples/golconda.nix { golconda = import ./default.nix; }).usrTree'`            | the `/usr` tree of the example configuration ([Configuration](config.md#the-entry-point))                                                                   |
| `nix-build -A packages.<system>.image-smoke`                                                              | the image chain over `examples/server.toml`, signed with throwaway keys                                                                                     |
| `scripts/boot-test <disk.raw> --keys DIR [FLAGS]`                                                         | boot an image in QEMU and check it; needs KVM, not the sandbox. The flags are in [Boot test](boot-test.md#flags)                                            |
| `scripts/provision-esp <disk.raw> [--hostname NAME] [--authorized-keys FILE] [--credential NAME=FILE]...` | write null-key credentials, which hold for one boot, to `loader/credentials/` on the ESP of a disk image, in place ([Boot test](boot-test.md#provisioning)) |
| `nix-build -A checks.x86_64-linux.docs`                                                                   | the book in the sandbox (generates the pages itself)                                                                                                        |
| `nix-build -A checks.<system>`                                                                            | the sandboxed checks ([Outputs](outputs.md#outputs))                                                                                                        |
| `iets eval --expr 'import ./nix/tests.nix { }'`                                                           | the module tests alone                                                                                                                                      |
| `./scripts/lint`                                                                                          | strict iets lint of the whole evaluation, the module tests, then the checks                                                                                 |
| `golconda vars set\|push\|list\|pub\|certify HOST …`                                                      | the admin vars of a machine, from the deploy host ([below](#golconda-vars))                                                                                 |
| `golconda release check\|publish\|build\|list …`                                                          | the release directory of an image: build, check, publish, list ([below](#golconda-release))                                                                 |
| `nix fmt`                                                                                                 | treefmt (the formatter output, built by repkgs): format in place and run the linters                                                                        |
| `scripts/docs serve`                                                                                      | check the module list in `docs/SUMMARY.md`, generate the module pages, then serve the book                                                                  |
| `scripts/pins check`, `scripts/pins apply NAME`                                                           | show and bump the pins in `pins/` with uptrack (`CONTRIBUTING.md`, "The repkgs fork")                                                                       |

The update test needs two releases with the same keys, and both are outputs:

```sh
nix-build -A packages.x86_64-linux.image-smoke-test -o test
nix-build -A packages.x86_64-linux.image-smoke-test-next -o next
scripts/boot-test test/disk/disk.raw --keys test/keys --secure-boot --next next
```

With `image-smoke-test-rotated` in place of `image-smoke-test-next`, add `--rotate`.

## The `golconda` tool

Build it from the Golconda tree at the revision of your pin
([Making a release: Get the tools](release.md#get-the-tools)). In a Golconda checkout,
`nix-build -A packages.x86_64-linux.golconda-cli` puts it at `result/bin/golconda`. It runs where an
operator works, not on a machine, and is not part of an image. The source is `cli/` (`cli/README.md`
is for developers). It calls other programs, found on `PATH`: `age`, `ssh`, `ssh-keygen`, `gpgv`,
`git`, `rclone` and `nix-build`. A variable replaces some of them, with arguments if you like
(`GOLCONDA_SSH="ssh -p 2222"`):

| variable                | program                                         | used by                                             |
| ----------------------- | ----------------------------------------------- | --------------------------------------------------- |
| `GOLCONDA_AGE`          | `age` (or `rage`)                               | `vars`                                              |
| `GOLCONDA_SSH`          | `ssh`                                           | `vars`                                              |
| `GOLCONDA_SSH_KEYGEN`   | `ssh-keygen`                                    | `vars certify`                                      |
| `GOLCONDA_AGE_IDENTITY` | the age identity file that `vars push -i` names | `vars push`, `vars certify`                         |
| `GOLCONDA_GPGV`         | `gpgv`                                          | `release check`, `release publish`, `release build` |

Golconda packages age as `packages.<system>.age` (`age` and `age-keygen`). Put it on `PATH` beside
`golconda`, with any `age-plugin-*` that the operators' keys need. age finds its plugins on `PATH`,
so a key can stay on a YubiKey or in a TPM.

### `golconda vars`

Admin vars are the values that an image names but never contains, such as a host certificate
([Trust: Secrets and vars](../design/trust.md#secrets-and-vars)). The deploy host keeps each one
age-encrypted in the configuration repository (`vars/<host>/<var>/<file>.age`, to the keys in
`vars/recipients.txt`; `--vars DIR` names another directory) and pushes it over ssh. The machine
seals it with its own `systemd-creds`, and the units that read it restart.

Make the age identity once, and add its public key to the recipients. Commit `vars/recipients.txt`,
never the key:

```sh
age-keygen -o ~/.config/age/key.txt
age-keygen -y ~/.config/age/key.txt >> vars/recipients.txt
```

HOST is the name that ssh reaches the machine by, and the directory of its vars in the store. It is
one word, so `user@host` is refused: give the machine an alias in `~/.ssh/config` (`Host web1` with
`HostName` and `User root`).

```sh
golconda vars certify -i ~/.config/age/key.txt web1 --ca-key host_ca --krl fleet.krl  # first
golconda vars set web1 sshd-revoked-keys krl < revoked.krl
golconda vars push -i ~/.config/age/key.txt web1     # every admin var web1 declares
golconda vars list web1                              # stored here? sealed there?
```

- `set HOST VAR FILE` reads the value from standard input and stores it encrypted.
- `push HOST [VAR…]` reads the manifests from the machine itself, never from an evaluation. It
  checks that every file is stored before it sends any, and restarts each consumer once. It needs
  the host key that `certify` stored (`vars/<host>/.hostkey`): without that file it refuses and
  names the `certify` command, and it refuses a machine with another host key. `-i` (or
  `GOLCONDA_AGE_IDENTITY`) names the identity that decrypts.
- `list HOST` says, for each file, whether it is stored here and sealed there. One more line says
  when the machine seals without PCR 7, from `golconda-var-run --reseal --without-pcr7` until the
  next `--reseal` ([Trust: PCR 7](../design/trust.md#pcr-7)).
- `pub HOST VAR FILE` prints the public file of a local var, such as the host key that a CA signs.
- `certify HOST --ca-key FILE` gives a machine its host certificate in one command
  ([below](#golconda-vars-certify)).

#### `golconda vars certify`

```sh
golconda vars certify -i ~/.config/age/key.txt web1 --ca-key host_ca --krl fleet.krl
golconda vars certify -i ~/.config/age/key.txt web1 --ca-key host_ca.pub \
  --pkcs11-module "$(ykcs11-module)" --principal web1.example.com --fingerprint SHA256:…
```

It runs these five steps in this order, and stops at the first failure:

1. Checks the request before it touches anything: each principal is one name, a KRL is given with
   `--krl` or already stored for HOST, and HOST declares both admin vars, `sshd-host-cert` and
   `sshd-revoked-keys`. Without any KRL it refuses: a certificate with no KRL would end plain-key
   login, while an image without `imageRevokedKeys` still refuses every user certificate.
1. Reads the host key over ssh, as `vars pub HOST sshd-hostkey key.pub` does, and prints its SHA-256
   fingerprint. Without `--fingerprint` it asks. Type `yes` if it is the fingerprint on the console
   or in the journal (`golconda: ssh host key …`); any other answer, or none, stops it. With
   `--fingerprint SHA256:…` it compares and refuses a mismatch without a question.
1. Signs the key as a host certificate with `ssh-keygen -s CA -h -I HOST -n PRINCIPALS -V VALIDITY`.
   The key id is HOST; the principals are the `--principal` names (repeat it), or HOST; the validity
   is `--validity` (default `-5m:+52w`, ssh-keygen's `-V` syntax). With `--pkcs11-module MODULE`,
   `--ca-key` is the CA's public key file and the token holds the private half
   (`ssh-keygen -D MODULE -s CA.pub`). ssh-keygen finds a token's key by its public half, not by a
   `pkcs11:` URI, and `ssh-keygen -D MODULE` prints the token's public keys. It asks for the token's
   PIN itself.
1. Stores the KRL (when `--krl` is given) and the certificate, as `vars set` does, and the host key
   in plain text as `vars/HOST/.hostkey`.
1. Pushes both, as `vars push HOST sshd-revoked-keys sshd-host-cert` does: the KRL first and the
   certificate last, then one restart of sshd.

Nothing is stored before the key is confirmed and signed, and nothing is pushed before both are
stored. The certificate is the last thing sealed, and a sealed certificate is what ends plain-key
login on the machine, at sshd's restart after both. So when the push fails, sshd has not restarted
and the machine still takes plain keys. What it sealed takes effect at sshd's next start: at most a
new KRL, or both when only the restart failed. The error says how to push again. Renewal is the same
command before the certificate expires.

To rotate a var, `set` and `push` again. A pushed value goes to whichever machine answers for the
host name. `push` compares the host key with `.hostkey`, but the machine reports that key itself, so
ssh's own host-key check is what makes it the right one. Keep that check on (`known_hosts`, or
step-ca host certificates with a `@cert-authority` line), and never give `GOLCONDA_SSH` an option
that turns it off, such as `StrictHostKeyChecking=no`.

### `golconda release`

A release is the directory `release/` that an image build writes: four files and an index
`SHA256SUMS` with its signature `SHA256SUMS.gpg` ([Releases](../design/releases.md)).
[Making a release](release.md) says how to use the commands together. `build`, `check` and `publish`
take the key set made by `scripts/make-keys`.

```sh
golconda release build -f server.toml --keys /srv/golconda-keys [--version auto] [--to DEST] [--out DIR] [--system SYSTEM]
golconda release check result-release/release --keys /srv/golconda-keys [--json]
golconda release publish result-release/release --to hetzner:updates/web --keys /srv/golconda-keys
golconda release list --to hetzner:updates/web
```

- `build` builds and signs a release from the document, checks it, and commits the new version
  ([Making a release: Build and sign](release.md#2-build-and-sign)). `--version` is `auto` by
  default. `--out` names a new directory (default `result-release`). `--pcr-keys` names the key set
  of the PCR key in a `db` rotation ([Rotate a key](release.md#5-rotate-a-key)). `--system` is the
  Nix system to evaluate for (default: this host's). `--pkcs11-module FILE` names the module of the
  token that holds the `db` or PCR key ([Keys on a token](release.md#6-keys-on-a-token)).
- `check` verifies the index (the four lines in their fixed order), every digest, the shared image
  id and version in the names, the UUIDs against the root hash, and the signature against the key
  set's `release/index.pgp`.
- `publish` checks the directory, then uploads it with rclone to a local directory or a
  `remote:path`. It refuses three things: a version that is not newer than the one the destination
  serves, the same version with other files, and a release whose commit (`--repo`, default `.`)
  records other digests. A release that no commit records needs `--unrecorded`. It deletes nothing
  and commits nothing.
- `list` prints the release commits, newest first; `--image ID` keeps those of one image. With
  `--to` it marks the one the destination serves and those it still holds.
