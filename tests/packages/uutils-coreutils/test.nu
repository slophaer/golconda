# uutils coreutils: the multicall binary and its per-tool symlinks do the everyday jobs.
# PATH holds only the seed, so every tool is called by its path in the package.
use checks.nu *
let bin = $"($env.pkg)/bin"
let t = $"($env.TMPDIR? | default /tmp)/uutils-smoke"
mkdir $t

assert "ls is a link to coreutils" ((^readlink $"($bin)/ls" | str trim) == "coreutils")
assert "version is the pin" ((^$"($bin)/coreutils" --version | str trim) | str contains "0.12.0")
assert "ls -la / lists the root" ((^$"($bin)/ls" -la / | lines | length) > 3)

"hello\n" | save -f $"($t)/a"
^$"($bin)/cp" $"($t)/a" $"($t)/b"
assert "cp copies" ((open --raw $"($t)/b") == "hello\n")

^$"($bin)/install" -m 0640 $"($t)/a" $"($t)/c"
assert "install -m sets the mode" ((^$"($bin)/stat" -c %a $"($t)/c" | str trim) == "640")

# sha256 of "hello\n"
assert "sha256sum" ((^$"($bin)/sha256sum" $"($t)/a" | split row " " | first) == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")

let e = (^$"($bin)/env" -i A=1 $"($bin)/env" | str trim)
assert "env -i clears the environment" ($e == "A=1")

done
