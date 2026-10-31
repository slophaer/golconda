# Configuration format

A Golconda configuration is a TOML document where each table sets options for one module. Validate
it against the schema before evaluation; type errors from adios tell you what the module expected.

## Document format

Table names are adios absolute paths, starting with `/`:

```toml
["/system"]
name = "myserver"
version = "2026.10.0"

["/services/sshd"]
port = 22
authorizedKeys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample admin@example.com",
]

# Certificates: uncomment to enable
# trustedUserCAKeys = ["ssh-ed25519 AAAA... user-ca-key"]
# ["/services/sshd".principals]
# root = ["admin@example.com"]
```

Unknown table names (paths that do not match a module) throw with the list of valid paths.

## Valid paths

Every module with options has a path. Run:

```sh
nix-instantiate --eval -E '(import ./default.nix).configLib.validPaths' --strict
```

Current paths:

| path             | options                                                                   |
| ---------------- | ------------------------------------------------------------------------- |
| `/system`        | `name`, `version`, `fragments`                                            |
| `/services/sshd` | `package`, `port`, `authorizedKeys`, `trustedUserCAKeys`, `principals`, … |

## Validation

Export the schema and use any JSON Schema validator:

```sh
# Export the schema
iets eval --json -E '(import ./default.nix).schema' > schema.json

# Convert TOML to JSON (requires yj or similar)
yj -tj < examples/server.toml > config.json

# Validate with ajv (npm install -g ajv-cli)
ajv validate -s schema.json -d config.json
```

Golconda does not ship a validator in the image yet. Type errors from adios show what the module
expected; the schema is for editors and external tools.

## Using the configuration

```nix
let
  f = import ./default.nix;
  cfg = f.configLib.loadConfig ./examples/server.toml;
  tree = f.modules cfg;
  sshd = tree.modules.services.modules.sshd { };
in
sshd
```

`loadConfig` parses the TOML and returns `{ options = {...}; }`. Pass it to `f.modules` to get an
evaluated tree. Call each module to get its fragment.

## Nix escapes

TOML covers the common path. Nix stays necessary for:

- Custom modules (service definitions not in the tree)
- Packages not in repkgs (overlays, local derivations)
- Complex logic (conditionals on hardware, shared values)

A future `imports` key may let TOML configs reference Nix modules.
