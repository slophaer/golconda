# Tests for the /usr tree builder's link-target conversion. They call the
# function the builder uses (main.nu), not a copy of it.
#
# Run from the repo root (checks.usr-tree-test runs it so):
#   nu --no-config-file --include-path lib/usr-tree tests/usr-tree/test.nu
use main.nu make-relative

def check [name: string, got: string, want: string] {
  if $got != $want {
    error make {msg: $"($name): got '($got)', want '($want)'"}
  }
  print $"ok: ($name)"
}

def check-error [name: string, link: string, target: string] {
  let got = (try { make-relative $link $target } catch {|e| $e.msg })
  if not ($got | str starts-with "link ") {
    error make {msg: $"($name): expected an error, got '($got)'"}
  }
  print $"ok: ($name)"
}

# An absolute target under /usr/ is relative to the link's directory within
# the image's /usr, not to its root.
check "same directory" (make-relative "/usr/lib/a" "/usr/lib/b") "b"
check "one level up" (make-relative "/usr/lib/systemd/system/multi-user.target.wants/sshd.service" "/usr/lib/systemd/system/sshd.service") "../sshd.service"
check "sibling directory" (make-relative "/usr/lib/a" "/usr/share/zoneinfo/UTC") "../share/zoneinfo/UTC"
check "link directly in /usr" (make-relative "/usr/a" "/usr/lib/b") "lib/b"
# The shared prefix ends at the first differing component: a name that
# matches after it (foo here) is not shared.
check "later component matches" (make-relative "/usr/lib/foo/l" "/usr/share/foo/t") "../../share/foo/t"
check "later components match, deeper" (make-relative "/usr/lib/a/b/c/l" "/usr/lib/x/b/c/t") "../../../x/b/c/t"
check "target is an ancestor directory" (make-relative "/usr/lib/a/b/l" "/usr/lib") "../.."

# A store path keeps the existing relative form.
check "store path from /usr/bin" (make-relative "/usr/bin/jq" "/nix/store/abc-jq/bin/jq") "../nix/store/abc-jq/bin/jq" # store-path-ok
check "store path from /usr/lib/systemd/system" (make-relative "/usr/lib/systemd/system/foo.service" "/nix/store/xyz/lib/systemd/system/foo.service") "../../../nix/store/xyz/lib/systemd/system/foo.service" # store-path-ok

# A relative target stays as it is.
check "relative target" (make-relative "/usr/lib/systemd/system/multi-user.target.wants/sshd.service" "../sshd.service") "../sshd.service"

# Any other absolute target is refused, with the link and the target named.
check-error "absolute target outside /usr" "/usr/lib/a" "/etc/passwd"
check-error "absolute target outside the store" "/usr/lib/a" "/var/lib/x"
