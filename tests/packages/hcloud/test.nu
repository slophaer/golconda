# hcloud without an account: the version, and that a command needing a token fails by saying so
# instead of reaching the network.
use checks.nu *
let hcloud = $"($env.pkg)/bin/hcloud"
assert "version is the pin" ((^$hcloud version | str trim) == "hcloud 1.70.2")
$env.HCLOUD_CONFIG = $"($env.TMPDIR? | default /tmp)/hcloud-test.toml"
let r = (^$hcloud server list | complete)
assert $"without a token it fails and says why: ($r.stderr)" ($r.exit_code != 0 and ($r.stderr | str lowercase | str contains "token"))
done
