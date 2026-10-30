# Commands

The commands a developer and a release run. All are `iets` invocations or scripts in `scripts/`.

| command | does | |---|---| | `iets build -A packages.<system>.<name>` | build one package through
the configured builder | | `iets build -A checks` | the sandboxed checks: treefmt, docs, boundary |
| `./scripts/lint` | strict iets lint of the whole evaluation, then the checks | | `treefmt` |
format in place | | `mdbook serve docs` | the documentation | | `npins update` | bump the pins |
