# Commands

The commands a developer and a release run. All are `iets` invocations or scripts in `scripts/`.

| command                                          | does                                                                             |
| ------------------------------------------------ | -------------------------------------------------------------------------------- |
| `iets build -A packages.<system>.<name>`         | build one package or `/usr` tree through the configured builder                  |
| `nix-build -E '(import ./golconda.nix).usrTree'` | the `/usr` tree of a configuration ([Configuration](config.md#the-entry-point))  |
| `iets build -A checks.<system>`                  | the sandboxed checks ([Outputs](outputs.md#outputs))                             |
| `iets eval --expr 'import ./nix/tests.nix { }'`  | the module tests alone                                                           |
| `./scripts/lint`                                 | strict iets lint of the whole evaluation, the module tests, then the checks      |
| `treefmt`                                        | format in place                                                                  |
| `scripts/docs serve`                             | generate the module pages and `SUMMARY.md`, then serve the book                  |
| `npins update`                                   | bump the pins (the repkgs pin is edited by hand, see `patches/repkgs/README.md`) |
