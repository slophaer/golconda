# console

Golconda's console: the `golconda` command line, and the `golcondad` daemon with its web pages.
Rust, built with repkgs' toolchain like every Golconda package (`console/package.nix`,
`packages.<system>.golconda-console`).

- `core/`: the `golconda-core` library. It evaluates a system's document with Golconda's `mkSystem`
  through the `iets` binary, one process per evaluation, and reads its `config`, `schema` and
  `moduleDocs`; it finds options in the schema and in the TOML document.
- `core/src/vars.rs`: admin vars from the deploy host: the age-encrypted store, the machine's
  manifests over ssh, the push.
- `cli/`: the `golconda` binary.
- `daemon/`: `golcondad`, the daemon. This first part shows each system's configuration and its
  changes against git as web pages and JSON, and changes nothing.

## Use

```sh
golconda config show -f examples/server.toml          # every option, defaults marked
golconda config show --set -f examples/server.toml    # what the document sets
golconda config explain -f examples/server.toml /services/sshd port
golconda config explain --json -f server.toml /network networks.lan.network.DNS
golconda config set -f server.toml /services/sshd port 2222
golconda config set -f server.toml /network networks.lan '{ match = { Name = "en*" } }'
golconda config delete -f server.toml /services/sshd port
golconda config validate -f server.toml
golconda diff -f server.toml              # against git's HEAD
golconda diff -f server.toml --from other.toml --json
```

`set` and `delete` change only what they name: comments, order and spacing stay as written. They
write the document only once the result passes the schema (core/src/validate.rs, the keywords
lib/schema.nix emits) and evaluates as far as every module's checks (the /usr tree's derivation, not
built). A schema problem names the line in the document; nothing is written otherwise. A VALUE is
TOML, and text that is not TOML is a string: `port 2222` is a number, `name web` the string "web",
`name '"2222"'` the string "2222".

`diff` compares effective configurations (mkSystem's `config`, defaults included), not text, and
lists the operations from the other side to FILE: `set /services/sshd port 2222 (was 22)`,
`delete … (was …; now …, the default)`. Where both sides set a table it goes down to the keys that
differ; a module only one side has is one change. Another revision is evaluated from a copy beside
the document, removed afterwards.

Admin vars ([Trust: Secrets and vars](../docs/design/trust.md#secrets-and-vars)): the values a
machine's image names but never contains, such as its host certificate. They are kept in the
configuration repository, age-encrypted to the keys in `vars/recipients.txt`, and pushed over ssh;
the machine seals each one with its own `systemd-creds` and the units that read it restart.

```sh
golconda vars pub web1 sshd-hostkey key.pub > host.pub
ssh-keygen -s host_ca -h -I web1 -n web1 host.pub    # the host CA signs it: host-cert.pub
golconda vars set web1 sshd-host-cert cert < host-cert.pub
golconda vars set web1 sshd-revoked-keys krl < revoked.krl
golconda vars push -i ~/.config/age/key.txt web1     # every admin var web1 declares
golconda vars list web1                              # stored here? sealed there?
```

`push` reads the manifests from the machine itself, checks that every file is stored before it sends
any, and restarts each consumer once. Rotation is `set` and `push` again. `age` (or `rage`) and
`ssh` are programs on the deploy host: `GOLCONDA_AGE` and `GOLCONDA_SSH` replace them, with
arguments. Golconda packages age (`packages.<system>.age`: `age` and `age-keygen`, the reference
implementation); put it on PATH beside `golconda`, with any `age-plugin-*` the operators' keys need
(age finds its plugins on PATH, so a key can stay on a YubiKey or in a TPM).

A pushed value goes to whichever machine answers for the host name: ssh's own host-key check is what
makes it the right one. Keep it on (`known_hosts`, or step-ca host certificates with a
`@cert-authority` line), and never give `GOLCONDA_SSH` an option that turns it off, such as
`StrictHostKeyChecking=no`.

An option is a module path and an option path inside it, dotted below the first level. iets comes
from PATH, or `GOLCONDA_IETS`. The document must be inside a Golconda checkout (a directory above it
has `lib/system.nix`): evaluation is pure and reads files under the checkout only.

## The daemon

```sh
golcondad --system server=examples/server.toml --dev-identity alice:operator
# http://127.0.0.1:8796/systems/server/config/services/sshd?option=port
```

Pages: `/systems/NAME/config` (the module tree and every module's documentation),
`/systems/NAME/config/MODULE?option=OPTION` (option rows and the option's detail),
`/systems/NAME/changes` (the working tree against git's HEAD, as `golconda diff`). Each answers JSON
for `Accept: application/json`. The pages are server-rendered HTML with no script and no request to
another origin; the content security policy allows only the daemon's own stylesheet and fonts. The
look is the mockups'. The IBM Plex fonts (packages/ibm-plex-web) are compiled in when
`GOLCONDA_FONTS` names their directory at build time; without it the pages use the system's fonts.

Every page needs someone signed in. In production that is OpenID Connect: the daemon is a client of
the provider (the authorization code flow with PKCE), and the provider's `groups` claim gives the
level, operator or read-only; someone in neither group is refused.

```sh
golcondad --listen 0.0.0.0:8796 --system server=server.toml \
  --oidc-issuer https://idp.example.com --oidc-client-id golconda-console \
  --public-url https://console.example.com \
  --operator-group golconda-operators --read-only-group golconda-readers
```

The provider must know `<public-url>/auth/callback` as a redirect URI. The daemon checks the ID
token itself (RS256 or ES256, the issuer, the audience, the expiry, the nonce), keeps sessions in
memory (a restart signs everyone out) in an `HttpOnly`, `SameSite=Lax` cookie, `Secure` when the
public URL is https, and answers only to the public URL's host name. `/auth/me` says who is signed
in, as JSON. A provider that wants a client secret gets it from `--oidc-client-secret-file`. The
issuer must use https, except on loopback. Its TLS certificate is checked against the public roots
built into the daemon, or, with `--oidc-ca-file`, against our own CA's certificates (step-ca)
instead.

For development, `--dev-identity NAME:LEVEL` signs everyone in as NAME at LEVEL (`operator` or
`read-only`), and the daemon then listens on a loopback address only and answers to loopback names.
`--read-only` makes the whole daemon say it changes nothing (nothing writes yet in any case). Every
page evaluates its system again (0.1 to 0.4 s; two evaluations for Changes).

The sign-in tests run a stub provider (daemon/tests/oidc.rs) with the test keys in
daemon/tests/fixtures: it signs tokens and checks the PKCE verifier, and it issues tokens that must
be refused (another key, audience, issuer or nonce, expired, `none`, `HS256`, a mislabelled
algorithm).

## Changing the configuration

With `--state DIR` the daemon writes: it keeps a candidate per system, the committed document plus
the operations not yet committed, in `DIR/journal.db`, and its audit log in `DIR/audit`.

```sh
golcondad --system server=checkout/server.toml --state /var/lib/golcondad \
  --signing-key /etc/golcondad/ssh_key --push origin --audit-push origin ...
```

- `POST /systems/NAME/ops`: `{ base, module, option, op: "set"|"delete", value }` (the value as
  TOML). Refused with 409 when an operation after `base` touched the same path, a path inside it or
  one that contains it, and with 422 when it adds a problem the schema finds.
- `POST /systems/NAME/commit` `{ message }`: fetch the remote (a change made there is recorded as an
  outside change, and stops the commit if it touched what the candidate changes), write the
  candidate into the document, validate it (schema, then evaluation), commit it, signed with the
  `--signing-key`, with the operator as author and the others as `Co-authored-by`, and push it to
  `--push` on the checkout's current branch. A push that fails leaves the commit local.
- `POST /systems/NAME/discard`; `GET /systems/NAME/candidate`.

The CLI works through such a daemon with `--server URL --name NAME`: `config set` and
`config delete` become operations on the revision it reads first (or `--base N`), and
`config candidate`, `config commit -m TEXT` and `config discard` work on the candidate. It cannot
sign in through OIDC yet (the device flow): today it reaches a daemon in development mode.

The remote is fetched every `--fetch-every` seconds too. Every action and every refusal (a conflict,
a problem, a write by someone who may only read, or in a `--read-only` daemon: 403) is an audit
entry, written before the answer; an entry that cannot be written refuses the action. Entries go to
the systemd journal as well (`GOLCONDA_ACTION=`, `GOLCONDA_OPERATOR=`, …), and the audit log is
pushed to `--audit-push` in the background.

In the browser the same works without a script. An operator gets a form in each option's detail: the
control follows the option's type (two radio buttons, a select, a number field with the schema's
bounds, a text field, one list item per line, or raw TOML), "Save to candidate", and "Reset to
default". A value the candidate changed shows amber in the option rows. A conflict answers with the
conflict page: both values, who and when, and keep theirs, apply mine on top, or edit again. The
Changes page shows the candidate's operations and what they change against the commit, with "Commit
and push" and "Discard all". Every form carries the session's CSRF token, and its Origin must be the
daemon's own; someone who may only read gets no form at all. `/audit` lists the audit log, newest
first, filtered by operator, system, action and day; as JSON with `Accept: application/json`.

## Audit log

The daemon keeps an audit log in a git repository of its own: one entry per commit, one JSON line
added to the file of its day (`2026/11/05.jsonl`), the operator as the author, the daemon as the
committer, signed with its SSH key, and a summary with trailers (`Operator:`, `Action:`, `System:`,
`Result:`, `Config-Commit:`) as the message. Anyone with a clone can check it:

```sh
golconda audit verify --repo audit --allowed-signers allowed_signers
```

`allowed_signers` names the daemon's key (or its CA, `cert-authority`) in git's format. Every commit
must be signed by it, add exactly one entry and remove nothing.

## Develop

cargo, rustc and the C linker come from repkgs (`pkgs.rust` and the set's `toolchain`), so they need
a build host for repkgs (docs/reference/build-host.md). With them and iets on PATH:

```sh
cd console
cargo test                          # unit tests, and the CLI's that need no evaluation
cargo test -- --include-ignored     # also the CLI against examples/server.toml, through iets
```

The ignored tests need iets and the checkout around this directory, which the package build does not
have. `treefmt` formats the Rust code and runs the ast-grep rules in `lints/rust/`;
`nix-build -A checks.x86_64-linux.console-clippy` runs clippy at the levels in `Cargo.toml`.
