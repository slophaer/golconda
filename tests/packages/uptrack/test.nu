# uptrack as the console runs it: `uptrack list` with UPTRACK_ROOT on a small tree, from another
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
cd /
rm -rf $t
done
