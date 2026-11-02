# Schema acceptance tests

`default.nix` exports the input fixtures with their Nix results. It forces `mkSystem` output for
public inputs. It also calls each library type's `verify` function for rows with a `definition`. The
`updateSource` rows use `mkSystem`, so they check the system boundary too.

`validate.py` checks the exported schema against JSON Schema 2020-12. It then checks each input
against both the schema and its expected Nix result. The check uses Python's `jsonschema` package
from the pinned developer tools. No validator ships in the image.

Every example TOML file enters the table after `builtins.fromTOML` converts it to data.
`examples/bad.toml` must fail; the other examples must pass. The JSON fixtures cover null values,
which TOML cannot express. They contain input options, not the normalized `{ value; explicit; }`
rows from `config.json`.

## Limits

JSON cannot encode a Nix derivation or function. These tests do not prove parity for Nix-only
package overrides. Library fixtures use types that can take JSON data.

Nix's `tryEval` cannot catch a missing-attribute evaluator error. The fixture runner checks for the
required system identity fields before it forces composition. Other invalid values must fail the
actual option types or composition; loader name checks alone do not suffice.

The local `var` struct allows unknown fields today. The fixture table keeps that behavior distinct
from strict types such as `adminVar`, `fragment`, `file`, and `link`.
