# console

Golconda's console: the `golconda` command line, and the `golcondad` daemon with its web pages.
Rust, built with repkgs' toolchain like every Golconda package (`console/package.nix`,
`packages.<system>.golconda-console`).

- `core/`: the `golconda-core` library. It evaluates a system's document with Golconda's `mkSystem`
  through the `iets` binary, one process per evaluation, and reads its `config`, `schema` and
  `moduleDocs`; it finds options in the schema and in the TOML document.
- `core/src/vars.rs`: admin vars from the deploy host: the age-encrypted store, the machine's
  manifests over ssh, the push.
- `core/src/release.rs`: release directories (docs/design/releases.md): the version grammar, the
  index and its signature.
- `cli/`: the `golconda` binary.
- `daemon/`: `golcondad`, the daemon: each system's configuration as web pages and JSON, a shared
  candidate, signed commits and an audit log.

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
memory (a restart signs everyone out; a session lasts 12 hours, and every lookup drops the expired
sessions and the sign-ins never finished) in an `HttpOnly`, `SameSite=Lax` cookie, `Secure` when the
public URL is https, and answers only to the public URL's host name. `/auth/me` says who is signed
in, as JSON. A provider that wants a client secret gets it from `--oidc-client-secret-file`. The
issuer must use https, except on loopback. Its TLS certificate is checked against the public roots
built into the daemon, or, with `--oidc-ca-file`, against our own CA's certificates (step-ca)
instead.

The CLI and the TUI sign in through the device flow with a public client of their own,
`--oidc-cli-client-id golconda-cli`. `/auth/device` tells them the issuer, that client and the
scopes; they then send the ID token as `Authorization: Bearer`. The daemon checks it as it checks a
browser's (signature, issuer, expiry, groups), but its audience must be the CLI client: a token
issued to the web client is not taken. A request with a bearer token carries no CSRF token, as it
comes from no form. Without `--oidc-cli-client-id` the daemon takes no bearer token.

For development, `--dev-identity NAME:LEVEL` signs everyone in as NAME at LEVEL (`operator` or
`read-only`), and the daemon then listens on a loopback address only and answers to loopback names.
`--read-only` makes the whole daemon change nothing: every write answers 403. Every page evaluates
its system again (0.1 to 0.4 s; two evaluations for Changes).

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
`config candidate`, `config commit -m TEXT` and `config discard` work on the candidate.

```sh
golconda --server https://console.example.com login    # open the address it prints, confirm the code
golconda --server https://console.example.com config candidate
golconda --server https://console.example.com logout
```

`login` runs the device flow against the provider the daemon names and keeps the ID token and the
refresh token per daemon in `$XDG_STATE_HOME/golconda/tokens.json` (`~/.local/state` without it; the
file is 0600, its directory 0700). Each call sends the ID token; one that expires within a minute is
renewed with the refresh token first, and when the provider refuses that, the CLI says to log in
again. `GOLCONDA_CA_FILE` names PEM certificates (our own CA's) that the provider's and the daemon's
TLS certificates must chain to. A daemon in development mode needs no login.

For a larger change an operator can take the system's lock ("configure exclusive"):
`POST /systems/NAME/lock` `{ minutes }` (30 without, at most a day), the Changes page's Lock, or
`golconda --server URL config lock --minutes 90`. While it lasts, only its holder changes the
candidate: anyone else's operation, commit, discard or unlock answers 423 with who holds it and
until when, and is an audit entry. Every system page shows the lock in its strip. It ends by itself;
its holder may give it up (`unlock`), and any operator may break it with a reason (`/lock/break`
`{ reason }`, `config break-lock --reason TEXT`), which the audit log keeps with the holder's name.

The remote is fetched every `--fetch-every` seconds too. Every action and every refusal (a conflict,
a problem, a write by someone who may only read, or in a `--read-only` daemon: 403) is an audit
entry, written before the answer; an entry that cannot be written refuses the action. Entries go to
the systemd journal as well (`GOLCONDA_ACTION=`, `GOLCONDA_OPERATOR=`, …), and the audit log is
pushed to `--audit-push` in the background by one thread: it pushes once for all the entries
recorded since its last push, and a push that fails is tried again every 30 seconds until it works,
without waiting for the next entry. Every page says that the log has entries its remote lacks, from
an entry until a push that holds it succeeds.

In the browser the same works without a script. An operator gets a form in each option's detail: the
control follows the option's type (two radio buttons, a select, a number field with the schema's
bounds, a text field, one list item per line, or raw TOML), "Save to candidate", and "Reset to
default". A value the candidate changed shows amber in the option rows. A conflict answers with the
conflict page: both values, who and when, and keep theirs, apply mine on top, or edit again. The
Changes page shows the candidate's operations and what they change against the commit, with "Commit
and push" and "Discard all". Every form carries the session's CSRF token, and its Origin must be the
daemon's own; someone who may only read gets no form at all. `/audit` lists the audit log, newest
first, filtered by operator, system, action and day; as JSON with `Accept: application/json`. It
reads from an index (`STATE/audit-index.db`) that the daemon makes from the repository at every
start and adds each entry to; the repository is the record, the index can be thrown away.

## TUI

```sh
golconda --server https://console.example.com tui
```

The daemon's screens in a terminal (ratatui), a client of the same JSON routes as the CLI and with
its login: `1` status (the machines; `u` update, `b` reboot, `R` roll back, `D` deploy, each after a
`y`), `2` configuration (modules, options, detail; `e` edits the selected option in a line editor
and saves it to the candidate, as TOML or, when it is not TOML, as a string; `D` resets it to its
default), `3` packages, `4` changes (the candidate's operations and what they change; `c` commit
with a message, `x` discard, `B` break someone's lock with a reason), `5` jobs (their output, read
again every second while one runs). `l` takes or gives up the lock, `r` refreshes (and every ten
seconds), `q` quits. The strip names the system, the image, the candidate's changes and the lock. A
conflict, a refusal or a lock says so on the message line.

## Live updates

Every page loads one optional script, `/assets/live.js` (under 10 KB, no framework, `defer`); the
pages work the same without it. It listens to the system's Server-Sent Events,
`/systems/NAME/events?page=PATH`: `rev` (an operation, a commit, a discard), `lock`, `job` (each
output line, and the end) and `presence` (who has which page of the system open, from the open
streams). With it a notice says who changed what; the Changes and configuration pages show the
change in place, unless someone is typing in a form there; the strip names who else is on the
system; a job's page appends its lines as they come instead of reloading every three seconds; and
forms are sent without a full reload. The content security policy stays: the script is the daemon's
own file, nothing is inline.

## Machines and jobs

`machines.toml` beside a system's document names its machines and its update source:

```toml
[server]
updates = "hetzner:updates/web"    # where a deploy publishes; the machines' /system.updateSource
[server.machines.web1]
ssh = "root@web1.example.com"
```

The daemon reads a machine over ssh with systemd's own varlink interfaces, `varlinkctl` run on it
(the image has no other tools): `io.systemd.Hostname` (hostname, image and version, boot id),
`io.systemd.BootControl` (the boot entries, which one is booted, which comes next, the boot
counters) and `io.systemd.SysUpdate` (`CheckNew`: a newer version at the update source; one it
cannot reach is "could not check", not an error). `/systems/NAME/machines` shows them, the Status
page, with the jobs an operator may start.

A job is `update` (sysupdate writes the newest version to the free slot), `reboot`
(`io.systemd.Shutdown.Reboot`, which an inhibitor stops; then it waits for the machine to come back
on the version its loader boots next, blessed), `rollback` (`bootctl set-oneshot` the other slot,
reboot, wait) or `deploy`, the whole system: `release build` in the system's checkout (the release
commit's author is the operator, the daemon commits and signs it and pushes it to `--push`),
`release publish` to `updates`, then on one machine after the other update, reboot, confirm; the
first that fails stops it, and the job names the machines it did not get to. A deploy needs
`--release-keys DIR` (and `--release-copy-keys` with a chroot-store build daemon).

Each system has one queue, so its jobs run one after the other. A job's state and output lines are
in `STATE/jobs.db`: `/jobs` and `/jobs/ID` show them (a running job's page reloads itself), as JSON
too (`?after=N`: the lines after line N). Every job is an audit entry when it is queued and when it
ends, a deploy's build and publish one each. A restart marks a job that had not ended interrupted;
nothing resumes it. `--confirm-timeout` (900 s) is how long a job waits for a machine to come back.
ssh, nix-build, gpgv and rclone come from PATH or `GOLCONDA_SSH`, `GOLCONDA_NIX_BUILD`,
`GOLCONDA_GPGV`, `GOLCONDA_RCLONE`.

```sh
golconda --server https://console.example.com machines
golconda --server https://console.example.com job start update web1 --wait
golconda --server https://console.example.com job start deploy --wait
golconda --server https://console.example.com job list
```

## Packages

`/systems/NAME/packages` lists the image's packages from its SBOM (CycloneDX), which mkSystem makes
and the console evaluates without building anything (0.3 s): the ones the image names itself first,
then what they need, each with its version, its origin (`golconda`, `repkgs`, or the downstream
repository that adds it), its purl and its cpe, and what a downstream replacement stands in for.
`/systems/NAME/sbom.json` is the CycloneDX document; JSON lists the packages.
`golconda packages -f server.toml` prints the same, `--sbom` the document.

### Known vulnerabilities (OSV)

The page also shows the known vulnerabilities of each package, from [OSV](https://osv.dev). The
daemon asks `POST /v1/querybatch` for the packages that have a purl (a purl without a version gets
the package's version as `version`), then `GET /v1/vulns/ID` once for each id it finds, for its
summary and severity. OSV indexes the ecosystems it knows (pypi, npm, cargo, Go, distributions, …):
a purl of another type (`pkg:github`, `pkg:generic`, which most of the image has) answers "none
known", and that means OSV has no records under that purl, not that the package is clean. A package
without a purl is not asked about and shows a dash.

The answers are kept, each with the time it was asked, for `--osv-every` seconds (six hours); with
`--state DIR` in `DIR/advisories.json`, so a restart keeps them. A page view asks OSV only for what
is missing or older, so a view within the lifetime makes no request at all. "checked 3 h ago" is the
age of the oldest answer on the page. When OSV cannot be reached the page still comes, with "could
not check" and the reason, and any older answer still shows; the daemon leaves OSV alone for five
minutes after a failure instead of waiting for it on every view. `--osv-url URL` names another OSV
server (a mirror, or a stub in tests); `--no-osv` never asks, and the page says "not checked".

The vulnerable packages come first (then the ones the image names itself), and `?show=vulnerable`
lists only them. JSON from the route is an object:
`{ "packages": [...], "advisories": { "checkedAt": 1730000000, "error": null } }`, `advisories`
being `null` when the daemon does not ask. Each package has `advisories`, a list of
`{ id, summary, severity }`, `[]` for "none known", and `null` when it was not asked about. The
severity is the word OSV's record carries (`database_specific.severity`, such as `HIGH`), which only
some records have; the CVSS vector is not read.

`golconda packages -f server.toml --advisories [--osv-url URL]` does the same from the command line:
vulnerable packages first, each followed by its advisories, and a last line saying when OSV was
asked or why it could not be. Its answers are kept in `$XDG_CACHE_HOME/golconda/advisories.json`
(`~/.cache/golconda` without it) for the same six hours. The TUI's packages screen shows the ids
after each package.

### Age and newer upstream versions

A package whose `sources.toml` has a `[pin] date` shows "from 2025-05-18, 538 days old" under its
version, on the page (`pinned`, `ageDays` in the JSON) and in `golconda packages`. The console reads
the date itself, in the evaluation that gives it the SBOM: `[pin] date` of the `sources.toml` beside
each package. The SBOM stays as repkgs' generator writes it; about half of the pins have a date.

The newest upstream version comes from uptrack (repkgs' tool, `pkgs/up/uptrack`), which learns it
only by asking the network. It is not a package of repkgs or of Golconda (repkgs' `shell.nix` has
nushell for it), so the console runs it as a program:

```sh
GOLCONDA_UPTRACK="nu /path/to/repkgs/pkgs/up/uptrack/src/uptrack" golcondad \
  --system server=server.toml --uptrack-tree /path/to/repkgs
```

For every `--uptrack-tree` the daemon finds the packages of the image that the tree tracks (a
directory of that name with a `sources.toml` that has `[upstream] purl`) and runs
`UPTRACK_ROOT=TREE uptrack check NAME… --json`. From each plan entry it takes `to` (the newer
version, `outdated`), `pin.date` (its release date), and `error` or `note` (why uptrack cannot say).
The page marks the package "outdated" with the newer version, lists the outdated ones after the
vulnerable ones, and has `?show=outdated`.

uptrack takes seconds to minutes, so a page view never waits for it. The first view starts one run
in the background and says "checking now"; the answers appear on a later view. They are kept for
`--uptrack-every` seconds (six hours; `DIR/upstream.json` with `--state`), and a view asks nothing
while they are good. A run is stopped after 30 minutes; a failed one is not repeated for five
minutes, and the older answers stay on the page with "could not check" and uptrack's message. JSON:
each package has `upstream` (`{ newest, outdated, released, error }`, `null` when no tree tracks it)
and the route has a top-level `upstream` (`{ checkedAt, error, running }`, `null` when uptrack is
not set up). uptrack keeps its own cache of what it fetched under `$XDG_CACHE_HOME/uptrack`, and
uses `GITHUB_TOKEN` or `gh`'s login against GitHub's rate limit.

`golconda packages -f server.toml --upstream --uptrack-tree DIR` does the same and waits for
uptrack, with its answers kept in `$XDG_CACHE_HOME/golconda/upstream.json`; the TUI shows "->
VERSION" after a package that has a newer one.

What uptrack needs, and where that stops this:

- uptrack is a nushell script that loads its modules by paths relative to itself (it reaches
  `builder/sys-libs.nu`), so it runs from a repkgs checkout, and `nu` must be on the daemon's PATH.
  The tree it works on can be elsewhere (`UPTRACK_ROOT`).
- It reads every `sources.toml` of the tree and refuses the whole run if one has a key it does not
  know. The repkgs tree passes. Golconda's own `packages/` does not: `dbus-broker`, `mtools`,
  `systemd` and `ukify` have `url` under `[upstream]`, which the pinned uptrack rejects, so
  `--uptrack-tree packages` ends in "could not check" until those files or uptrack change. The
  packages of the image that come from Golconda therefore show no upstream version today.
- Its names are directory names, and its datasources are the purl types it knows (`github`,
  `gitlab`, `pypi`, `cargo`, `npm`, `hackage`, `gnu`, `generic`, …). A package it cannot resolve
  (`pkg:deb`, `pkg:sourceforge`) shows uptrack's message.
- It compares with the tree's pin, not with the version in the image: they are the same when the
  tree is the one the image was built from.

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

## Releases

```sh
golconda release build -f server.toml --keys /srv/golconda-keys [--version auto] [--to DEST]
```

`build` refuses a working tree with uncommitted changes to tracked files (untracked files do not
count). It picks the version: `auto` is today's date (UTC) and the revision after the newest of the
document's `/system` version (the last one built here) and, with `--to`, the destination's; a
version given must be newer than both. It writes that version into the document (comments and layout
stay: it is the only change it makes), builds `lib.mkImage { config; keys; system; }`'s `disk` with
`nix-build` in the Golconda checkout around the document, links the output at `--out-link` (default
`result-release`), runs `check` on its `release/`, and commits the version line:
`release: <id> <version>`, with the trailers that `publish` reads. That commit's tree is what was
built. A failed build, check or commit puts the version line back. The key set goes to `mkImage` as
a string, so its private keys stay out of the store (the daemon needs `extra-sandbox-paths` for it,
docs/reference/release.md); `--copy-keys` copies it in whole, for a daemon with a chroot store,
which sees no path outside it. The build goes through `nix-build`, not iets: the image's outputs are
content-addressed, and iets 0.2 builds them but reports no output path. `nix-build` and git come
from PATH, or `GOLCONDA_NIX_BUILD` and `GOLCONDA_GIT`; `nix-build` reaches the daemon `NIX_REMOTE`
names. The user's git configuration (author, signing, hooks) applies.

A build writes a release directory (`release/`): four files, the index `SHA256SUMS` and its
signature `SHA256SUMS.gpg` ([Releases](../docs/design/releases.md)). Check one before serving it:

```sh
golconda release check result/release --keys /srv/golconda-keys
```

It refuses an index without exactly the four lines in their fixed order (usr, verity, signature,
UKI), a digest that does not match its file, names that do not share one image id and one version
(`YYYYMMDD.N`, the grammar of `lib/version.nix`), UUIDs in the names that are not the halves of the
root hash the verity signature names, and a signature that `gpgv` does not accept from the key set's
`release/index.pgp`, the key the machines carry. `--json` prints the id, version, root hash and
files.

```sh
golconda release publish result/release --to hetzner:updates/web --keys /srv/golconda-keys
golconda release list --to hetzner:updates/web
```

`publish` checks the directory, then puts it where machines fetch from: anything rclone reaches, a
local directory (an HTTP server's root) or `remote:path` (S3 and S3-compatible stores, SFTP, …) of
the operator's `rclone.conf` or `RCLONE_CONFIG_*`. It refuses a version that is not newer than the
one the destination serves, and the same version with other files: machines that have a version
never fetch it again. It looks up the release commit (`release: <id> <version>`, with the trailers
`Release-Image`, `Release-Version`, `Config`, `Usr`, `Verity`, `Signature`, `Uki`, `Store-Path`) in
the repository (`--repo`, default `.`, any ref) and refuses a release whose commit records other
digests, or that has none unless `--unrecorded`. The four files go up first, then the signature,
then the index, each to a temporary name and renamed where the backend has renames; then it reads
the index back. It deletes nothing (an older release's files stay) and commits nothing, so it needs
no clean tree. Publishing the release a destination already serves is no error.

`list` prints the release commits, newest first, and with `--to` marks the one the destination
serves and those it still holds; the destination is the record of what was published.

## Develop

cargo, rustc and the C linker come from repkgs (`pkgs.rust` and the set's `toolchain`), so they need
a build host for repkgs (docs/reference/build-host.md). The tests also run git, ssh-keygen and gpg.
With them and iets on PATH:

```sh
cd console
cargo test                          # unit tests, and the CLI's that need no evaluation
cargo test -- --include-ignored     # also the CLI against examples/server.toml, through iets
```

The ignored tests need iets and the checkout around this directory, which the package build does not
have. `treefmt` formats the Rust code and runs the ast-grep rules in `lints/rust/`;
`nix-build -A checks.x86_64-linux.console-clippy` runs clippy at the levels in `Cargo.toml`.
