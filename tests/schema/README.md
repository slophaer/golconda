# Schema acceptance tests

`default.nix` exports the input fixtures with their Nix results. It forces `mkSystem` output for
public inputs. It also calls each library type's `verify` function for rows with a `definition`. The
`updateSource` rows use `mkSystem`, so they check the system boundary too.

`checks.schema-parity` checks each input against both the schema and its expected Nix result. The
schema's verdict is the console's validator (`console/core/src/validate.rs`, the one
`golconda validate` and the daemon run), through `console/core/examples/schema-parity.rs`; it also
fails when the schema uses a keyword the validator does not check. `checks.schema-metaschema`
(`metaschema.py`) checks the schema against JSON Schema 2020-12 with Python's `jsonschema`, a whole
implementation of the draft, from the pinned developer tools. No validator ships in the image.

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

A fragment is no longer configuration (a downstream module returns it), so the fragment rows are
library rows of the `fragment` type. Where a fragment may write (under `/usr`, canonical, no control
characters) is the composer's rule, checked in `tests/eval/composer.nix`, not a type the schema
pairs with.

The local `var` struct allows unknown fields today. The fixture table keeps that behavior distinct
from strict types such as `adminVar`, `fragment`, `file`, and `link`.
