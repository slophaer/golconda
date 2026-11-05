# etc.nu: the image's /etc as a directory confext (lib/etc.nix runs it).
#
# Structured attrs: tmpfiles, sysusers (Golconda's lines, as /usr/lib/{tmpfiles,sysusers}.d/
# golconda.conf has them), systemdTmpfiles, systemdSysusers (systemd's directories), factory
# (path under /usr/share/factory/etc -> text), extensionRelease.
#
# First boot, run at build time: systemd-tmpfiles --prefix=/etc and systemd-sysusers over the
# image's own configuration, against an empty root that holds only the factory. The result is
# the /etc a first boot would write, minus machine-id (an empty file: PID 1 mounts the id over
# it) and minus the enable links of first-boot presets (an empty machine-id means no first
# boot; Golconda enables units with static .wants links).
#
# /etc is then read-only, so the /etc lines of tmpfiles must not run again at boot: a `d`
# line whose mode differs (the store makes every directory 0555) would chmod and fail with
# EROFS. The confext carries etc/tmpfiles.d/<name>.conf for each configuration that has /etc
# lines, with those lines dropped; /etc/tmpfiles.d overrides /usr/lib/tmpfiles.d by name.
#
# A line that writes a credential into /etc (`f^ /etc/hosts - - - - network.hosts`) is kept,
# moved to /run/golconda/etc/<path>, and /etc/<path> is a link there: the credential still
# works, and /etc stays read-only.
#
# No shadow: every account is locked and has no password (Golconda has none), so passwd and
# group say `!*` in the password field instead of `x`. pam_unix then never looks for a shadow
# entry (Linux-PAM modules/pam_unix/passverify.c, get_account_info), and the store's 0444 mode
# would have made /etc/shadow world-readable.
use common.nu *

const stage = "stage"
const conf = "conf"
const credDir = "/run/golconda/etc"

# Is this tmpfiles line about a path under /etc? (type, then the path)
def etc-line [line: string] {
  let f = ($line | str trim | split row -r '\s+')
  ($f | length) >= 2 and not ($f.0 | str starts-with "#") and (($f.1 == "/etc") or ($f.1 | str starts-with "/etc/"))
}

# Does this /etc line take its content from a credential? (a `^` in the type)
def cred-line [line: string] {
  (etc-line $line) and (($line | str trim | split row -r '\s+' | first) | str contains "^")
}

# The credential line, moved from /etc/<path> to /run/golconda/etc/<path>
def to-run [line: string] {
  let f = ($line | str trim | split row -r '\s+')
  $f | update 1 ($f.1 | str replace -r '^/etc/' $"($credDir)/") | str join " "
}

# The line with user and group as "-": the build runs unprivileged and erofs makes every
# file root's (--all-root). Any other owner under /etc is an error, not a silent change.
def unowned [line: string] {
  if not (etc-line $line) { return $line }
  let f = ($line | str trim | split row -r '\s+')
  if ($f | length) < 5 { return $line }
  for o in [$f.3 $f.4] {
    if not ($o in ["-" "root" "0" ""]) {
      error make {msg: $"tmpfiles line owns a path under /etc by ($o), but /etc is built as root's: ($line)"}
    }
  }
  $f | update 3 "-" | update 4 "-" | str join " "
}

# A relative link text from the directory of /etc/<rel> to the absolute target
def relative-to [rel: string, target: string] {
  # one .. for each directory between the link and /, /etc included
  let up = (1..($rel | path split | length) | each { ".." } | str join "/")
  $"($up)/($target)"
}

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = $a.LD_LIBRARY_PATH

  # The factory, where C! and L lines read it
  for p in ($a.factory | columns) {
    let dest = $"($stage)/usr/share/factory/etc/($p)"
    mkdir ($dest | path dirname)
    $a.factory | get $p | save -f $dest
  }

  # The configurations: systemd's, then Golconda's own, owners neutralized
  mkdir $"($conf)/tmpfiles.d" $"($conf)/sysusers.d"
  let tmpfiles = (
    ls $a.systemdTmpfiles | where {|e| $e.name | str ends-with ".conf" } | get name
    | each {|f| {name: ($f | path basename), text: (open --raw $f)} }
    | append [{name: "golconda.conf", text: $a.tmpfiles}]
  )
  for t in $tmpfiles {
    $t.text | lines | each {|l| unowned $l } | str join "\n" | $in + "\n" | save -f $"($conf)/tmpfiles.d/($t.name)"
  }
  ls $a.systemdSysusers | where {|e| $e.name | str ends-with ".conf" } | get name | each {|f| ^cp -L $f $"($conf)/sysusers.d/" } | ignore
  $a.sysusers | save -f $"($conf)/sysusers.d/golconda.conf"

  mkdir $"($stage)/etc"
  # the boot's order: sysusers before tmpfiles, which may name the users
  log "systemd-sysusers"
  ^systemd-sysusers $"--root=($stage)" ...(ls $"($conf)/sysusers.d" | get name)
  log "systemd-tmpfiles --create --boot --prefix=/etc"
  ^systemd-tmpfiles $"--root=($stage)" --create --boot --prefix=/etc ...(ls $"($conf)/tmpfiles.d" | get name)
  rm -f $"($stage)/etc/.pwd.lock"

  # No shadow: every password field becomes `!*` (locked, not shadowed)
  for db in [passwd group] {
    let p = $"($stage)/etc/($db)"
    open --raw $p | lines | each {|l|
      let f = ($l | split row ":")
      if ($f | length) > 2 and $f.1 == "x" { $f | update 1 "!*" | str join ":" } else { $l }
    } | str join "\n" | $in + "\n" | save -f $p
  }
  rm -f $"($stage)/etc/shadow" $"($stage)/etc/gshadow"

  # machine-id: an empty file, so PID 1 bind-mounts the id over it (machine-id(5))
  "" | save -f $"($stage)/etc/machine-id"

  # The tmpfiles overrides: each configuration with /etc lines, without them
  for t in $tmpfiles {
    let ls = ($t.text | lines)
    if ($ls | any {|l| etc-line $l }) {
      mkdir $"($stage)/etc/tmpfiles.d"
      [$"# Generated by Golconda, lib/image/etc.nu: /usr/lib/tmpfiles.d/($t.name) without its"
       "# /etc lines, which ran at build time; /etc is read-only."]
      | append ($ls | each {|l| if (cred-line $l) { to-run $l } else { $l } } | where {|l| not (etc-line $l) })
      | str join "\n" | $in + "\n" | save -f $"($stage)/etc/tmpfiles.d/($t.name)"
    }
  }

  # /etc/<path> of each credential line links to its place under /run (it may dangle: no
  # credential, no file)
  for t in $tmpfiles {
    for l in ($t.text | lines | where {|l| cred-line $l }) {
      let p = ($l | str trim | split row -r '\s+' | get 1)
      let dest = $"($stage)($p)"
      mkdir ($dest | path dirname)
      rm -f $dest
      ^ln -s $"($credDir)($p | str replace -r '^/etc' '')" $dest
    }
  }

  # Absolute link targets become relative to the link's place under /etc: the /usr tree
  # refuses absolute links, and /etc is mounted at /etc, so ../usr/... resolves there.
  let root = ($"($stage)/etc" | path expand)
  let links = (glob --no-file --no-dir $"($root)/**/*" | where {|l| (^readlink $l | str trim | str starts-with "/") })
  for l in $links {
    let rel = ($l | str replace $"($root)/" "")
    let target = (^readlink $l | str trim)
    rm $l
    ^ln -s (relative-to $rel ($target | str substring 1..)) $l
  }

  # The confext's identity: this image and this version only
  mkdir $"($stage)/etc/extension-release.d"
  $a.extensionRelease | save -f $"($stage)/etc/extension-release.d/extension-release.golconda"

  mkdir $out
  ^cp -a $"($stage)/etc" $"($out)/etc"
  log $"(glob $"($out)/etc/**/*" | length) entries"
}
