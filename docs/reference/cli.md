# Commands

The commands a developer and a release run. All are `iets` invocations or scripts in `scripts/`.

| command                                                                                                                                                                     | does                                                                                                                                        |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `iets build -A packages.<system>.<name>`                                                                                                                                    | build one package or `/usr` tree through the configured builder                                                                             |
| `nix-build -E '(import ./examples/golconda.nix).usrTree'`                                                                                                                   | the `/usr` tree of the example configuration ([Configuration](config.md#the-entry-point))                                                   |
| `iets build -A packages.<system>.image-smoke`                                                                                                                               | the image chain over `examples/server.toml`, with `proof.txt`                                                                               |
| `scripts/boot-test <disk.raw> --keys DIR [--secure-boot] [--tpm] [--timeout SECONDS] [--ssh-test [--esp-creds]] [--next DIR [--rotate \| --fail-health]] [--factory-reset]` | boot an image in QEMU and check it; needs KVM, not the sandbox ([Image artifacts](image.md#boot-test-scriptsboot-test))                     |
| `scripts/provision-esp <disk.raw> [--hostname NAME] [--authorized-keys FILE] [--credential NAME=FILE]...`                                                                   | write null-key credentials to `loader/credentials/` on the ESP of a disk image, in place ([Boot test](image.md#boot-test-scriptsboot-test)) |
| `nix-build -A checks.x86_64-linux.docs`                                                                                                                                     | the book in the sandbox (generates the pages itself)                                                                                        |
| `iets build -A checks.<system>`                                                                                                                                             | the sandboxed checks ([Outputs](outputs.md#outputs))                                                                                        |
| `iets eval --expr 'import ./nix/tests.nix { }'`                                                                                                                             | the module tests alone                                                                                                                      |
| `./scripts/lint`                                                                                                                                                            | strict iets lint of the whole evaluation, the module tests, then the checks                                                                 |
| `golconda vars set\|push\|list\|pub HOST …`                                                                                                                                 | the admin vars of a machine, from the deploy host ([console/README.md](../../console/README.md))                                            |
| `treefmt`                                                                                                                                                                   | format in place                                                                                                                             |
| `scripts/docs serve`                                                                                                                                                        | check the module list in `docs/SUMMARY.md`, generate the module pages, then serve the book                                                  |
| `npins update`                                                                                                                                                              | bump the pins (the repkgs pin is edited by hand, see `patches/repkgs/README.md`)                                                            |

The update test needs two releases with the same keys, and both are outputs:

```sh
nix-build -A packages.x86_64-linux.image-smoke-test -o test
nix-build -A packages.x86_64-linux.image-smoke-test-next -o next
scripts/boot-test test/disk/disk.raw --keys test/keys --secure-boot --next next
```

With `image-smoke-test-rotated` in place of `image-smoke-test-next`, add `--rotate`.
