# main.nu: build the /usr tree from the composer output (lib/usr-tree.nix). The builder reads its
# inputs as structured attrs (`attrs`): closure, roots, links, packageBins, attribution, programs,
# files, units, sysusers, tmpfiles, packageList, osRelease, epoch, version, allowedDirs. A link of
# kind "farm" is expanded file by file; one of kind "dlopen" is verified to resolve.

def attrs [] {
  open $env.NIX_ATTRS_JSON_FILE
}

def log [msg: string] {
  print -e $"usr-tree: ($msg)"
}

# Split an absolute path into its components: /usr/lib/a -> [usr lib a]
def path-components [p: string]: nothing -> list<string> {
  $p | split row "/" | where {|c| $c != "" }
}

# Convert a link target to one relative to the link's directory in the image's
# /usr. Three kinds are supported:
#   a path under /usr/: relative to the link's directory within /usr
#     (/usr/lib/a -> /usr/lib/b is "b", not "../usr/lib/b")
#   a store path: relative to the image's /usr, so /usr/bin needs one ".."
#     (/usr/bin/jq -> ../nix/store/<hash>-jq/bin/jq)
#   a relative target: unchanged
# Any other absolute target is an error: it would point outside the image.
export def make-relative [link_path: string, target: string]: nothing -> string {
  if not ($target | str starts-with "/") {
    return $target
  }
  let link_dir = ($link_path | path dirname)
  if not (($link_dir == "/usr") or ($link_dir | str starts-with "/usr/")) {
    error make {msg: $"link ($link_path) is not under /usr/"}
  }
  # Components below /usr: /usr/lib/systemd -> [lib systemd]
  let link_parts = ((path-components $link_dir) | skip 1)
  if ($target | str starts-with "/usr/") {
    let target_parts = ((path-components $target) | skip 1)
    let depth = ([($link_parts | length) ($target_parts | length)] | math min)
    # The shared prefix ends at the first differing component; a name that
    # matches again after it is not shared.
    let first_diff = (0..<$depth | where {|i| ($link_parts | get $i) != ($target_parts | get $i) } | first 1)
    let shared = if ($first_diff | is-empty) { $depth } else { $first_diff | first }
    let ups = (0..<(($link_parts | length) - $shared) | each { ".." } | str join "/")
    let down = ($target_parts | skip $shared | str join "/")
    if $ups == "" { $down } else if $down == "" { $ups } else { $"($ups)/($down)" }
  } else if ($target | str starts-with "/nix/store/") { # store-path-ok
    let ups = (0..<($link_parts | length) | each { ".." } | str join "/")
    let target_rel = ($target | str replace -r "^/" "")
    if $ups == "" { $target_rel } else { $"($ups)/($target_rel)" }
  } else {
    error make {msg: $"link ($link_path): unsupported absolute target ($target): expected a path under /usr/, a store path, or a relative target"}
  }
}

# Inspect each parent before mkdir or a write can follow a symlink. Shared real
# directories are valid; even a dangling symlink is an existing claim.
def conflict [rel: string, source: string, dest: string] {
  let kind = ($dest | path type)
  let existing = if $kind == "symlink" { ^readlink $dest | str trim } else { $kind }
  error make {msg: $"destination conflict at /usr/($rel): ($source); existing ($kind) ($existing)"}
}

def ensure-directory [out: string, rel: string, source: string] {
  mut dest = $out
  if ($dest | path exists -n) {
    if ($dest | path type) != "dir" { conflict "" $source $dest }
  } else {
    mkdir $dest
  }
  mut prefix = []
  for component in (path-components $rel | where { $in != "." }) {
    $prefix = ($prefix | append $component)
    $dest = $"($dest)/($component)"
    if ($dest | path exists -n) {
      if ($dest | path type) != "dir" { conflict ($prefix | str join "/") $source $dest }
    } else {
      mkdir $dest
    }
  }
}

def guard-write [out: string, rel: string, source: string] {
  ensure-directory $out ($rel | path dirname) $source
  let dest = $"($out)/($rel)"
  if ($dest | path exists -n) { conflict $rel $source $dest }
}

# " from /a, /b" for an error message, or "" when the origins are not known
def from-origins [origins: list<string>]: nothing -> string {
  if ($origins | is-empty) { "" } else { $" from ($origins | str join ', ')" }
}

# The executable names one package puts in /usr/bin: its exports.json `bin` (what bin/
# holds after the build, no hidden launchers), or only the names it declares (pkg.bin).
# A declared name must be in exports.json too. A derivation repkgs did not build (a
# signed loader, a keyring) has no exports.json and no args: it puts nothing there.
export def package-bin-names [pkg: record]: nothing -> list<string> {
  let exports = $"($pkg.path)/exports.json"
  if not ($exports | path exists) {
    if $pkg.declared != null {
      error make {msg: $"golconda: package ($pkg.package) declares bin ($pkg.declared | str join ', ') but has no exports.json at ($exports)"}
    }
    return []
  }
  let built = (open $exports | get -o bin | default [])
  if $pkg.declared == null { return $built }
  let missing = ($pkg.declared | where { $in not-in $built })
  if ($missing | is-not-empty) {
    error make {msg: $"golconda: package ($pkg.package) declares bin ($missing | str join ', '), which its exports.json bin does not list: [($built | str join ', ')]"}
  }
  $pkg.declared
}

export def build [] {
  let attrs = (attrs)
  let out = $attrs.outputs.out
  let epoch = $attrs.epoch
  let closure = $attrs.closure

  $env.PATH = $attrs.PATH

  log $"building /usr tree version ($attrs.version)"
  log $"closure has ($closure | length) paths"

  for dir in ["nix/store" "bin" "lib/systemd/system" "lib/sysusers.d" "lib/tmpfiles.d" "lib/golconda" "share"] {
    ensure-directory $out $dir "fixed builder directory"
  }

  log "copying closure..."
  for p in $closure {
    let store_path = $p.path
    let basename = ($store_path | path basename)
    let dest = $"($out)/nix/store/($basename)"
    log $"  ($basename)"
    guard-write $out $"nix/store/($basename)" $"closure copy from ($store_path)"
    ^cp -a $store_path $dest
  }

  log "creating sbin -> bin"
  guard-write $out "sbin" "fixed sbin alias"
  ^ln -s "bin" $"($out)/sbin"

  let plain_links = ($attrs.links | where kind != "farm")
  let farm_links = ($attrs.links | where kind == "farm")
  log $"creating ($plain_links | length) symlinks..."
  for link in $plain_links {
    let path = $link.path
    let target = $link.target
    let dest_rel = ($path | str replace "/usr/" "")
    let dest = $"($out)/($dest_rel)"
    let dest_dir = ($dest | path dirname)

    guard-write $out $dest_rel $"($link.kind) link from ($target)"

    let rel_target = (make-relative $path $target)

    ^ln -s $rel_target $dest

    # A target under /usr/ must resolve to that path in the image's /usr. A wrong prefix count
    # gives a link that resolves elsewhere (../usr/lib/b from /usr/lib/a lands on /usr/usr/lib/b).
    if ($target | str starts-with "/usr/") {
      let want = ($"($out)/($target | str replace -r '^/usr/' '')" | path expand)
      let link_text = (^readlink $dest | str trim)
      let got = ($"($dest_dir)/($link_text)" | path expand)
      if $got != $want {
        error make {msg: $"link ($path) -> ($target) resolves to ($got), not ($want)(from-origins ($link.origins? | default [])): make-relative gave ($link_text)"}
      }
    }
  }

  # /usr/bin/<name> for the executables of each package (package-bin-names). A name from two
  # sources stops the build and names both: two packages, or a package and a plain link.
  log $"linking the executables of ($attrs.packageBins | length) packages..."
  mut bin_claims = ($plain_links | where { ($in.path | path dirname) == "/usr/bin" }
    | reduce -f {} {|l, acc| $acc | upsert $l.path $"($l.kind) link to ($l.target)(from-origins ($l.origins? | default []))" })
  mut bin_links = []
  for pkg in $attrs.packageBins {
    let what = $"package ($pkg.package)(from-origins $pkg.origins)"
    for name in (package-bin-names $pkg) {
      let path = $"/usr/bin/($name)"
      let first = ($bin_claims | get -o $path)
      if $first != null {
        error make {msg: $"golconda: ($path) defined twice: ($first), ($what)"}
      }
      let target = $"($pkg.path)/bin/($name)"
      if not ($target | path exists) {
        error make {msg: $"golconda: package ($pkg.package) lists ($name) in bin, but ($target) does not exist"}
      }
      guard-write $out $"bin/($name)" $"($what) link from ($target)"
      ^ln -s (make-relative $path $target) $"($out)/bin/($name)"
      $bin_claims = ($bin_claims | upsert $path $what)
      $bin_links = ($bin_links | append {path: $path, origins: $pkg.origins})
    }
  }

  # Expand farm directories file by file, subdirectories included: systemd's lib/systemd/system
  # carries its static enablement as <target>.wants/ directories, and a farm of lib/systemd must
  # reach them. A file that two farms bring from the same place is fine (a farm of lib/systemd
  # and one of lib/systemd/system overlap); a different source is a collision.
  log $"expanding ($farm_links | length) farm directories..."
  mut farm_sources = {}
  for dir in $farm_links {
    let path = $dir.path
    let target = $dir.target
    let dest_rel = ($path | str replace "/usr/" "")
    let dest_dir = $"($out)/($dest_rel)"

    ensure-directory $out $dest_rel $"farm directory from ($target)"

    if not ($target | path exists) {
      error make {msg: $"farm link ($path): directory ($target) does not exist"}
    }
    # complete: a failed find must stop the build, not look like an empty tree
    let found = (^find $target -mindepth 1 '(' -type f -o -type l ')' -print | complete)
    if $found.exit_code != 0 {
      error make {msg: $"farm link ($path): find ($target) failed: ($found.stderr)"}
    }
    let files = ($found.stdout | lines | where { $in != "" } | sort)
    for file in $files {
      let rel = ($file | path relative-to $target)
      let dest_file = $"($dest_dir)/($rel)"
      let rel_target = (make-relative $"($path)/($rel)" $file)

      let claim = $"($dest_rel)/($rel)"
      ensure-directory $out ($claim | path dirname) $"farm file from ($file)"
      if ($dest_file | path exists -n) {
        # Only a previous farm claim can repeat, not an ordinary link to the same source.
        if ($farm_sources | get -o $claim) == $file { continue }
        conflict $claim $"farm file from ($file)" $dest_file
      }

      ^ln -s $rel_target $dest_file
      $farm_sources = ($farm_sources | upsert $claim $file)
    }
  }

  log $"writing ($attrs.files | columns | length) files..."
  for entry in ($attrs.files | transpose path value) {
    let path = $entry.path
    let file = $entry.value
    let dest = $file.dest

    if $dest == null {
      error make {msg: $"file path ($path) is not under /usr/"}
    }

    let dest_path = $"($out)/($dest)"
    guard-write $out $dest $"configured file ($path)"

    $file.text | save $dest_path
    ^chmod $file.mode $dest_path
  }

  log $"writing ($attrs.units | columns | length) units..."
  for entry in ($attrs.units | transpose name text) {
    let rel = $"lib/systemd/system/($entry.name)"
    guard-write $out $rel $"unit ($entry.name)"
    $entry.text | save $"($out)/($rel)"
  }

  if ($attrs.sysusers | length) > 0 {
    log $"writing sysusers.d/golconda.conf \(($attrs.sysusers | length) lines\)"
    let content = ($attrs.sysusers | str join "\n")
    guard-write $out "lib/sysusers.d/golconda.conf" "generated sysusers"
    $content | save $"($out)/lib/sysusers.d/golconda.conf"
  }

  if ($attrs.tmpfiles | length) > 0 {
    log $"writing tmpfiles.d/golconda.conf \(($attrs.tmpfiles | length) lines\)"
    let content = ($attrs.tmpfiles | str join "\n")
    guard-write $out "lib/tmpfiles.d/golconda.conf" "generated tmpfiles"
    $content | save $"($out)/lib/tmpfiles.d/golconda.conf"
  }

  log "writing lib/os-release"
  guard-write $out "lib/os-release" "generated os-release"
  $attrs.osRelease | save $"($out)/lib/os-release"

  log "writing lib/golconda/packages.json"
  guard-write $out "lib/golconda/packages.json" "generated package list"
  $attrs.packageList
  | each {|p| if $p.version == null { $p | reject version } else { $p } }
  | to json
  | save $"($out)/lib/golconda/packages.json"

  # attribution.json: the composer's origins, and the bin/ links with their package's origins
  log "writing lib/golconda/attribution.json"
  guard-write $out "lib/golconda/attribution.json" "generated attribution"
  mut links_origins = ($attrs.attribution | get -o links | default {})
  for l in $bin_links { $links_origins = ($links_origins | upsert $l.path $l.origins) }
  let attribution = if ($bin_links | is-empty) { $attrs.attribution } else {
    $attrs.attribution | upsert links ($links_origins | sort)
  }
  $attribution | to json | save $"($out)/lib/golconda/attribution.json"

  if $attrs.sbomPath != null {
    log "copying sbom.json"
    guard-write $out "lib/golconda/sbom.json" $"SBOM from ($attrs.sbomPath)"
    ^cp $attrs.sbomPath $"($out)/lib/golconda/sbom.json"
  }

  # mtimes are not set here: Nix normalises every store path to mtime 1. The version-derived
  # timestamp (epoch) is applied by mkfs.erofs -T when the image is made (lib/image/erofs.nix).

  log "verifying..."

  # no absolute symlink targets; -lname tests the link text, so a relative link needs no
  # readlink/grep pipeline (whose "no match" exit status is 1)
  let found_abs = (^find $out -type l -lname '/*' -print | complete)
  if $found_abs.exit_code != 0 {
    error make {msg: $"find failed while checking symlink targets: ($found_abs.stderr)"}
  }
  let abs_links = ($found_abs.stdout | lines | where { $in != "" })
  if ($abs_links | length) > 0 {
    error make {msg: $"absolute symlink targets found: ($abs_links | str join ', '); the nix/store/<hash>-NAME in each names the package that ships it, so give the link a relative target there"}
  }

  # dlopen links resolve
  for link in ($attrs.links | where kind == "dlopen") {
    let dest = $"($out)/($link.path | str replace "/usr/" "")"
    # -n: the link itself, not what it points to (a dangling link exists)
    if not ($dest | path exists -n) {
      error make {msg: $"dlopen link ($link.path) was not created(from-origins ($link.origins? | default [])): the builder's link step skipped it"}
    }
    let target = (ls -l $dest | get target.0)
    let full_target = if ($target | str starts-with "/") {
      $target
    } else {
      $"($dest | path dirname)/($target)" | path expand
    }
    if not ($full_target | path exists) {
      error make {msg: $"dlopen link ($link.path) -> ($target) does not exist(from-origins ($link.origins? | default [])): the package that holds the target must be in the closure"}
    }
  }

  # no top-level directory outside the allowed ones
  let top_level = (ls $out | get name | each { $in | path basename })
  let allowed = $attrs.allowedDirs
  let bad = ($top_level | where { $in not-in $allowed and $in != "sbin" })
  if ($bad | length) > 0 {
    error make {msg: $"files outside allowed dirs: ($bad | str join ', '); the top-level directories of /usr are ($allowed | str join ', ')"}
  }

  # every program a unit runs is in bin/: a name the package does not install, or a link that
  # dangles, fails here and not at boot
  for program in $attrs.programs {
    if not ($"($out)/bin/($program.name)" | path exists) {
      let who = if ($program.origins | is-empty) { "a unit" } else { $program.origins | str join ', ' }
      error make {msg: $"golconda: /usr/bin/($program.name) does not exist in the /usr tree, but ($who) runs it"}
    }
  }

  # the target of each tmpfiles L line under /usr exists: a misspelt time zone would leave
  # /etc/localtime dangling on the machine
  for line in $attrs.tmpfiles {
    let fields = ($line | split row -r '\s+' | where { $in != "" })
    if ($fields | length) < 7 or not ($fields.0 | str starts-with "L") { continue }
    let target = ($fields | skip 6 | str join " ")
    if not ($target | str starts-with "/usr/") { continue }
    if not ($"($out)/($target | str replace "/usr/" "")" | path exists) {
      error make {msg: $"golconda: tmpfiles link ($fields.1) -> ($target): ($target) does not exist in the /usr tree"}
    }
  }

  log "verification passed"
  log $"usr tree complete: ($out)"
}
