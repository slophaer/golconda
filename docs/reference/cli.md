# Commands

The commands a developer and a release run. All are `iets` invocations or scripts in `scripts/`.

| command                                  | does                                                      |
| ---------------------------------------- | --------------------------------------------------------- |
| `iets build -A packages.<system>.<name>` | build one package through the configured builder          |
| `iets build -A checks.<system>`          | the sandboxed checks: treefmt, docs, boundary             |
| `./scripts/lint`                         | strict iets lint of the whole evaluation, then the checks |
| `treefmt`                                | format in place                                           |
| `scripts/docs serve`                     | the documentation                                         |
| `npins update`                           | bump the pins                                             |

## golconda diff *(planned)*

Compares two images by their `/usr/lib/golconda/` artifacts:

```sh
golconda diff <image-a> <image-b>
```

Inputs:

- `config.json`: the resolved options of each image
- `sbom.json`: the CycloneDX SBOM of each image

Output: a path-based set/delete list showing what changed:

```json
[
  {"op": "set", "path": "/services/sshd/port", "value": 2222},
  {"op": "delete", "path": "/services/nginx"}
]
```

The diff doubles as an edit log and a patch format.
