# btrfs-progs on a file: mkfs.btrfs makes a filesystem in a 200 MiB sparse file, btrfs check
# reads it back. Needs no root, no loop device, no mount.
use checks.nu *
let bin = $"($env.pkg)/bin"
let img = $"($env.TMPDIR? | default /tmp)/btrfs-test.img"
rm -f $img
^truncate -s 200M $img
assert "sparse file has the size" ((ls -l $img | get 0.size | into int) == 209715200)

let mk = (^$"($bin)/mkfs.btrfs" -L golconda $img | complete)
assert $"mkfs.btrfs succeeds: ($mk.stderr)" ($mk.exit_code == 0)
assert "mkfs reports the label" ($mk.stdout | str contains "Label:              golconda")

let chk = (^$"($bin)/btrfs" check $img | complete)
assert $"btrfs check succeeds: ($chk.stdout) ($chk.stderr)" ($chk.exit_code == 0)
assert "btrfs check found no errors" (($chk.stdout ++ $chk.stderr) | str contains "no error")

# the check looks at the image: with the primary superblock (64 KiB) and its mirror (64 MiB) zeroed it fails
^dd if=/dev/zero $"of=($img)" bs=1 seek=65536 count=4096 conv=notrunc
^dd if=/dev/zero $"of=($img)" bs=1 seek=67108864 count=4096 conv=notrunc
let bad = (^$"($bin)/btrfs" check $img | complete)
assert $"btrfs check rejects zeroed superblocks: ($bad | to json)" ($bad.exit_code != 0)
rm -f $img
done
