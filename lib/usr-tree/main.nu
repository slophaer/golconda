# main.nu: build the /usr tree from the composer output.
#
# Called by the Nix derivation with structured attrs:
#   closure: reference graph of the packages
#   roots: list of store paths (the packages)
#   links: list of { path, target, kind } for symlinks; kind "farm" names a directory
#     to expand file by file, kind "dlopen" is verified to resolve
#   files: attrset of path -> { text, mode, dest }
#   units: attrset of name -> text
#   sysusers, tmpfiles: lists of lines
#   packageList: list of { name, version?, path, origins } for lib/golconda/packages.json
#   osRelease: rendered os-release text
#   epoch: Unix timestamp for mtimes
#   version: image version string
#   allowedDirs: list of allowed top-level dirs

# Read the structured attrs
def attrs [] {
  open $env.NIX_ATTRS_JSON_FILE
}

# Log a message to stderr
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

# Main entry point
export def build [] {
  let attrs = (attrs)
  let out = $attrs.outputs.out
  let epoch = $attrs.epoch
  let closure = $attrs.closure

  # Set PATH from attrs
  $env.PATH = $attrs.PATH

  log $"building /usr tree version ($attrs.version)"
  log $"closure has ($closure | length) paths"

  # Create output directory structure
  mkdir $out
  mkdir $"($out)/nix/store"
  mkdir $"($out)/bin"
  mkdir $"($out)/lib"
  mkdir $"($out)/lib/systemd/system"
  mkdir $"($out)/lib/sysusers.d"
  mkdir $"($out)/lib/tmpfiles.d"
  mkdir $"($out)/lib/golconda"
  mkdir $"($out)/share"

  # Step 1: Copy the closure to nix/store
  log "copying closure..."
  for p in $closure {
    let store_path = $p.path
    let basename = ($store_path | path basename)
    let dest = $"($out)/nix/store/($basename)"
    log $"  ($basename)"
    ^cp -a $store_path $dest
  }

  # Step 2: Create sbin -> bin symlink
  log "creating sbin -> bin"
  ^ln -s "bin" $"($out)/sbin"

  # Step 3: Create symlinks from the links list (every kind but farm)
  let plain_links = ($attrs.links | where kind != "farm")
  let farm_links = ($attrs.links | where kind == "farm")
  log $"creating ($plain_links | length) symlinks..."
  for link in $plain_links {
    let path = $link.path
    let target = $link.target
    # Strip /usr/ prefix
    let dest_rel = ($path | str replace "/usr/" "")
    let dest = $"($out)/($dest_rel)"
    let dest_dir = ($dest | path dirname)

    # Create parent directory
    mkdir $dest_dir

    # Make target relative
    let rel_target = (make-relative $path $target)

    # Create symlink
    ^ln -sf $rel_target $dest

    # A target under /usr/ must resolve to that path in the image's /usr:
    # compare the created link's resolved path with the path the target names.
    # A wrong prefix count gives a link that resolves elsewhere (../usr/lib/b
    # from /usr/lib/a lands on /usr/usr/lib/b), so this stops the build.
    if ($target | str starts-with "/usr/") {
      let want = ($"($out)/($target | str replace -r '^/usr/' '')" | path expand)
      let link_text = (^readlink $dest | str trim)
      let got = ($"($dest_dir)/($link_text)" | path expand)
      if $got != $want {
        error make {msg: $"link ($path) -> ($target) resolves to ($got), not ($want)"}
      }
    }
  }

  # Step 4: Expand farm directories file by file, subdirectories included: systemd's
  # lib/systemd/system carries its static enablement as <target>.wants/ directories, and a
  # farm of lib/systemd must reach them. A file two farms both bring from the same place is
  # fine (a farm of lib/systemd and one of lib/systemd/system overlap); a different source is
  # a collision.
  log $"expanding ($farm_links | length) farm directories..."
  for dir in $farm_links {
    let path = $dir.path
    let target = $dir.target
    # Strip /usr/ prefix from path
    let dest_rel = ($path | str replace "/usr/" "")
    let dest_dir = $"($out)/($dest_rel)"

    # Create destination directory
    mkdir $dest_dir

    # Link every file of the source tree; a missing directory is an error
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

      if ($dest_file | path exists -n) {
        let existing_target = (ls -l $dest_file | get 0.target? | default "file")
        if $existing_target == $rel_target { continue }
        # Collision: error with both sources
        error make {msg: $"farm collision at ($path)/($rel): ($target) vs ($existing_target)"}
      }

      mkdir ($dest_file | path dirname)
      ^ln -sf $rel_target $dest_file
    }
  }

  # Step 5: Write files from system.files
  log $"writing ($attrs.files | columns | length) files..."
  for entry in ($attrs.files | transpose path value) {
    let path = $entry.path
    let file = $entry.value
    let dest = $file.dest

    if $dest == null {
      error make {msg: $"file path ($path) is not under /usr/"}
    }

    let dest_path = $"($out)/($dest)"
    let dest_dir = ($dest_path | path dirname)

    # Create parent directory
    mkdir $dest_dir

    # Write file
    $file.text | save -f $dest_path

    # Set mode (convert octal string to chmod format)
    let mode = $file.mode
    ^chmod $mode $dest_path
  }

  # Step 6: Write units to lib/systemd/system/
  log $"writing ($attrs.units | columns | length) units..."
  for entry in ($attrs.units | transpose name text) {
    let dest = $"($out)/lib/systemd/system/($entry.name)"
    $entry.text | save -f $dest
  }

  # Step 7: Write sysusers.d/golconda.conf
  if ($attrs.sysusers | length) > 0 {
    log $"writing sysusers.d/golconda.conf \(($attrs.sysusers | length) lines\)"
    let content = ($attrs.sysusers | str join "\n")
    $content | save -f $"($out)/lib/sysusers.d/golconda.conf"
  }

  # Step 8: Write tmpfiles.d/golconda.conf
  if ($attrs.tmpfiles | length) > 0 {
    log $"writing tmpfiles.d/golconda.conf \(($attrs.tmpfiles | length) lines\)"
    let content = ($attrs.tmpfiles | str join "\n")
    $content | save -f $"($out)/lib/tmpfiles.d/golconda.conf"
  }

  # Step 9: Write os-release
  log "writing lib/os-release"
  $attrs.osRelease | save -f $"($out)/lib/os-release"

  # Step 10: Write lib/golconda/packages.json (name, version when known, store path, origins)
  log "writing lib/golconda/packages.json"
  $attrs.packageList
  | each {|p| if $p.version == null { $p | reject version } else { $p } }
  | to json
  | save -f $"($out)/lib/golconda/packages.json"

  # Step 10b: Copy SBOM if one was provided
  if $attrs.sbomPath != null {
    log "copying sbom.json"
    ^cp $attrs.sbomPath $"($out)/lib/golconda/sbom.json"
  }

  # mtimes are not set here: Nix normalises every store path to mtime 1. The version-derived
  # timestamp (epoch) is applied by mkfs.erofs -T when the image is made (image/erofs.nix).

  # Step 11: Verification
  log "verifying..."

  # 11a: No absolute symlink targets. -lname tests the link text, so a relative
  # link needs no readlink/grep pipeline (whose "no match" exit status is 1).
  let found_abs = (^find $out -type l -lname '/*' -print | complete)
  if $found_abs.exit_code != 0 {
    error make {msg: $"find failed while checking symlink targets: ($found_abs.stderr)"}
  }
  let abs_links = ($found_abs.stdout | lines | where { $in != "" })
  if ($abs_links | length) > 0 {
    error make {msg: $"absolute symlink targets found: ($abs_links | str join ', ')"}
  }

  # 11b: dlopen links resolve
  for link in ($attrs.links | where kind == "dlopen") {
    let dest = $"($out)/($link.path | str replace "/usr/" "")"
    # -n: the link itself, not what it points to (a dangling link exists)
    if not ($dest | path exists -n) {
      error make {msg: $"dlopen link ($link.path) was not created"}
    }
    # Follow the symlink to verify the target exists
    let target = (ls -l $dest | get target.0)
    let full_target = if ($target | str starts-with "/") {
      $target
    } else {
      $"($dest | path dirname)/($target)" | path expand
    }
    if not ($full_target | path exists) {
      error make {msg: $"dlopen link ($link.path) -> ($target) does not exist"}
    }
  }

  # 11c: No setuid/setgid bits
  let found_setuid = (^find $out -perm /6000 -type f -print | complete)
  if $found_setuid.exit_code != 0 {
    error make {msg: $"find failed while checking setuid bits: ($found_setuid.stderr)"}
  }
  let setuid = ($found_setuid.stdout | lines | where { $in != "" })
  if ($setuid | length) > 0 {
    error make {msg: $"setuid/setgid files found: ($setuid | str join ', ')"}
  }

  # 11d: No files outside allowed top-level dirs
  let top_level = (ls $out | get name | each { $in | path basename })
  let allowed = $attrs.allowedDirs
  let bad = ($top_level | where { $in not-in $allowed and $in != "sbin" })
  if ($bad | length) > 0 {
    error make {msg: $"files outside allowed dirs: ($bad | str join ', ')"}
  }

  log "verification passed"
  log $"usr tree complete: ($out)"
}
