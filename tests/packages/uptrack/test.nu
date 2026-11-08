# uptrack outside a repkgs checkout: `uptrack list` with UPTRACK_ROOT on a small tree, from another
# directory, finds the modules it installs beside bin/ (pipeline.nu imports builder/sys-libs.nu)
# and reads the sources.toml files. `check` polls the network, so it is not run here.
use checks.nu *
let uptrack = $"($env.pkg)/bin/uptrack"
let t = $"($env.TMPDIR? | default /tmp)/uptrack-test"
rm -rf $t
mkdir $"($t)/pkgs/ab/alpha" $"($t)/pkgs/cd/beta" $"($t)/elsewhere"
'[upstream]
purl = "pkg:github/example/alpha"

[[source]]
key = "default"
url = "https://example.invalid/alpha-{version}.tar.gz"
hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

[pin]
version = "1.2.3"
' | save $"($t)/pkgs/ab/alpha/sources.toml"
'[upstream]
purl = "pkg:pypi/beta"

[[source]]
key = "default"
url = "https://example.invalid/beta-{version}.tar.gz"
hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

[pin]
version = "4.5"
' | save $"($t)/pkgs/cd/beta/sources.toml"
cd $"($t)/elsewhere"
$env.UPTRACK_ROOT = $t

let all = (^$uptrack list | complete)
assert $"list runs: ($all.stderr)" ($all.exit_code == 0)
assert "list names both packages with their pins" (["alpha" "pkg:github/example/alpha" "1.2.3" "beta" "pkg:pypi/beta" "4.5"] | all {|s| $all.stdout | str contains $s })
let one = (^$uptrack list beta | complete)
assert "list takes a name" (($one.stdout | str contains "beta") and not ($one.stdout | str contains "alpha"))
let bad = (^$uptrack list gamma | complete)
assert "an unknown name fails" (($bad.exit_code != 0) and ($bad.stderr | str contains "no sources.toml for gamma"))

# a key the format does not know is refused
'[upstream]
purl = "pkg:github/example/alpha"
colour = "red"
' | save -f $"($t)/pkgs/ab/alpha/sources.toml"
let wrong = (^$uptrack list | complete)
# (nu wraps a long error line, so only the key is matched)
assert "an unknown key fails, naming the key" (($wrong.exit_code != 0) and ($wrong.stderr | str contains "colour"))

# the forms pins/ uses: a branch head (`?branch=`, `{rev}`, and `base` from repkgs#204) and a
# frozen pin with no [pin]
'[upstream]
purl = "pkg:github/example/alpha?branch=main"
base = "2.36"

[[source]]
key = "default"
url = "https://example.invalid/alpha/{rev}.tar.gz"
hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

[pin]
version = "2.36-unstable-2026-11-08"
date = "2026-11-08"
rev = "0123456789abcdef0123456789abcdef01234567"
' | save -f $"($t)/pkgs/ab/alpha/sources.toml"
'[upstream]
frozen = "a channel build"

[[source]]
key = "default"
url = "https://example.invalid/beta.tar.xz"
hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
' | save -f $"($t)/pkgs/cd/beta/sources.toml"
let pins = (^$uptrack list | complete)
# (list leaves frozen ones out; a version this long wraps in the table, so the purl is matched)
assert $"a branch pin with a base and a frozen pin are read: ($pins.stderr)" (($pins.exit_code == 0) and ("pkg:github/example/alpha?branch=main" in $pins.stdout))

# nu has its network commands: a poll of a closed port fails as an I/O error, not as a
# missing `http` command ("External command failed": repkgs' nushell without `network`)
'[upstream]
purl = "pkg:generic/alpha?url=http://127.0.0.1:9/"

[[source]]
key = "default"
url = "https://example.invalid/alpha-{version}.tar.gz"
hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

[pin]
version = "1.2.3"
' | save -f $"($t)/pkgs/ab/alpha/sources.toml"
rm -rf $"($t)/pkgs/cd"
$env.XDG_CACHE_HOME = $"($t)/cache"
let poll = (^$uptrack check --json | complete)
let err = ($poll.stdout | from json | get 0.error? | default "")
assert $"polling reaches the network code: ($err) ($poll.stderr)" (($err != "") and ($err !~ "External command"))
cd /
rm -rf $t
done
