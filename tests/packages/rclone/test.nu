# rclone as golconda release publish uses it: copyto a named file into a destination and cat it
# back, once to a plain local path and once through a remote defined in the environment
# (RCLONE_CONFIG_<NAME>_TYPE), the way an operator's S3 or SFTP remote is named. No network.
use checks.nu *
let rclone = $"($env.pkg)/bin/rclone"
let t = $"($env.TMPDIR? | default /tmp)/rclone-test"
rm -rf $t
mkdir $t
$env.RCLONE_CONFIG = $"($t)/rclone.conf"
"" | save $env.RCLONE_CONFIG

assert "version is the pin" ((^$rclone --version | lines | first) == "rclone v1.75.2")

"SHA256SUMS of a release\n" | save $"($t)/src"
^$rclone copyto $"($t)/src" $"($t)/dest/web/SHA256SUMS"
assert "copyto makes the directories and writes the file" ((open --raw $"($t)/dest/web/SHA256SUMS") == "SHA256SUMS of a release\n")
# complete keeps the output as it is; a plain capture would drop the final newline
let cat = {|path| (^$rclone cat $path | complete).stdout }
assert "cat reads it back, byte for byte" ((do $cat $"($t)/dest/web/SHA256SUMS") == "SHA256SUMS of a release\n")
assert "no partial file stays" ((ls -a $"($t)/dest/web" | length) == 1)

$env.RCLONE_CONFIG_UPDATES_TYPE = "local"
^$rclone copyto $"($t)/src" $"updates:($t)/remote/SHA256SUMS"
assert "a remote from the environment works" ((do $cat $"updates:($t)/remote/SHA256SUMS") == "SHA256SUMS of a release\n")
assert "cat of a missing file fails" ((do { ^$rclone cat $"($t)/dest/nope" } | complete).exit_code != 0)
rm -rf $t
done
