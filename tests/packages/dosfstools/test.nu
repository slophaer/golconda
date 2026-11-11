# dosfstools: mkfs.fat takes its clock from SOURCE_DATE_EPOCH (the backported upstream patch,
# packages/dosfstools/source-date-epoch.patch), so the ESP the signer makes is the same bytes on
# every run. With it set, two runs give the same bytes, the volume label's entry carries the
# epoch's UTC date and time, the volume ID is the epoch unless -i gives one, and -i still wins
# (systemd-repart passes its own). Without it, two runs differ, but only where the clock goes:
# the volume ID in the boot sector and its backup, and the label entry's times.
use checks.nu *
let bin = $"($env.pkg)/bin"
let tmp = $"($env.TMPDIR? | default /tmp)/dosfstools"
rm -rf $tmp
mkdir $tmp
hide-env -i SOURCE_DATE_EPOCH

# 2023-11-14 22:13:20 UTC: FAT time 22:13:20 is 0xb1aa, date 2023-11-14 0x576e, the ID 0x6553f100
const EPOCH = "1700000000"
const LABEL = "GOLCONDA"

def raw [f: string]: nothing -> binary { open --raw $f | into binary }
# mkfs IMG ARGS: a FAT32 file system with the label in a fresh 64 MiB file, its bytes
def --wrapped mkfs [img: string, ...args: string]: nothing -> binary {
  rm -f $img
  ^truncate -s 64M $img
  let r = (^$"($bin)/mkfs.fat" -F 32 -n $LABEL ...$args $img | complete)
  assert $"mkfs.fat ($args | str join ' ') exits 0: ($r.stdout) ($r.stderr)" ($r.exit_code == 0)
  raw $img
}
# the N bytes at OFFSET, little-endian
def le [data: binary, offset: int, n: int]: nothing -> int { $data | bytes at $offset..<($offset + $n) | into int -e little }
# the volume label's directory entry: the 11-byte name with ATTR_VOLUME (0x08)
def label-entry [data: binary]: nothing -> int {
  $data | bytes index-of ((($LABEL | fill -w 11) | into binary) ++ 0x[08])
}
const VOLID = 0x43 # BS_VolID in a FAT32 boot sector
const BACKUP = 3072 # the backup boot sector, sector 6

# --- with SOURCE_DATE_EPOCH
let a = (with-env {SOURCE_DATE_EPOCH: $EPOCH} { mkfs $"($tmp)/a.img" })
let b = (with-env {SOURCE_DATE_EPOCH: $EPOCH} { mkfs $"($tmp)/b.img" })
assert "with SOURCE_DATE_EPOCH, two runs are the same bytes" ($a == $b)
let e = (label-entry $a)
assert "the image has the volume label's entry" ($e > 0)
assert $"the label's write time is the epoch's, in UTC: (le $a ($e + 22) 2)" ((le $a ($e + 22) 2) == 0xb1aa)
assert $"the label's write date is the epoch's: (le $a ($e + 24) 2)" ((le $a ($e + 24) 2) == 0x576e)
assert "the label's creation time and date are the same" (((le $a ($e + 14) 2) == 0xb1aa) and ((le $a ($e + 16) 2) == 0x576e))
assert $"without -i the volume ID is the epoch: (le $a $VOLID 4)" ((le $a $VOLID 4) == 1700000000)
let fsck = (^$"($bin)/fsck.fat" -n $"($tmp)/a.img" | complete)
assert $"fsck.fat accepts it: ($fsck.stdout) ($fsck.stderr)" ($fsck.exit_code == 0)

# -i wins over the epoch, in the boot sector and its backup; --mbr's disk signature is the ID
let i = (with-env {SOURCE_DATE_EPOCH: $EPOCH} { mkfs $"($tmp)/i.img" -i 56e477d6 --mbr=y })
assert $"-i gives the volume ID: (le $i $VOLID 4)" ((le $i $VOLID 4) == 0x56e477d6)
assert "the backup boot sector has it too" ((le $i ($BACKUP + $VOLID) 4) == 0x56e477d6)
assert $"--mbr's disk signature is the volume ID: (le $i 440 4)" ((le $i 440 4) == 0x56e477d6)
let j = (with-env {SOURCE_DATE_EPOCH: $EPOCH} { mkfs $"($tmp)/j.img" -i 56e477d6 --mbr=y })
assert "with -i and --mbr, two runs are the same bytes" ($i == $j)

# a SOURCE_DATE_EPOCH that is no number is refused
let bad = (with-env {SOURCE_DATE_EPOCH: "soon"} { ^truncate -s 64M $"($tmp)/bad.img"; ^$"($bin)/mkfs.fat" -F 32 $"($tmp)/bad.img" | complete })
assert $"SOURCE_DATE_EPOCH=soon fails the run: ($bad.stdout)" ($bad.exit_code != 0)

# --- without it: the runs differ, at the volume ID and the label entry's times only
let c = (mkfs $"($tmp)/c.img")
let d = (mkfs $"($tmp)/d.img")
assert "without SOURCE_DATE_EPOCH, two runs differ" ($c != $d)
let ec = (label-entry $c)
let clock = (
  [$VOLID ($BACKUP + $VOLID)] | each {|o| $o..($o + 3) | each {|x| $x } } | flatten
  | append ([14 15 16 17 18 19 22 23 24 25] | each {|x| $ec + $x })
)
let diff = (^cmp -l $"($tmp)/c.img" $"($tmp)/d.img" | lines | each {|l| ($l | str trim | split row -r '\s+' | first | into int) - 1 })
let stray = ($diff | where {|o| $o not-in $clock })
assert $"the runs differ only where the clock goes; elsewhere at: ($stray | first 8)" ($stray | is-empty)
rm -rf $tmp
done
