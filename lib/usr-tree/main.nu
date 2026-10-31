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

# Convert store path target to relative symlink from link location
def make-relative [link_path: string, target: string]: nothing -> string {
  if ($target | str starts-with "/") {
    # Absolute path: convert to relative
    let link_dir = ($link_path | path dirname)
    # Count depth from /usr: /usr/bin = 1, /usr/lib/systemd = 2
    # From a file in /usr/bin/, one .. reaches /usr/
    let stripped = ($link_dir | str replace "/usr/" "")
    let parts = ($stripped | split row "/" | where { $in != "" })
    let depth = ($parts | length)
    let ups = (0..($depth - 1) | each { ".." } | str join "/")
    # Target /nix/store/... -> nix/store/...
    let target_rel = ($target | str replace -r "^/" "")
    $"($ups)/($target_rel)"
  } else {
    # Already relative
    $target
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
  }

  # Step 4: Expand farm directories file by file
  log $"expanding ($farm_links | length) farm directories..."
  for dir in $farm_links {
    let path = $dir.path
    let target = $dir.target
    # Strip /usr/ prefix from path
    let dest_rel = ($path | str replace "/usr/" "")
    let dest_dir = $"($out)/($dest_rel)"

    # Create destination directory
    mkdir $dest_dir

    # Link every file of the source directory; a missing directory is an error
    if not ($target | path exists) {
      error make {msg: $"farm link ($path): directory ($target) does not exist"}
    }
    let files = (ls $target | where type == file or type == symlink)
    for file in $files {
      let basename = ($file.name | path basename)
      let dest_file = $"($dest_dir)/($basename)"

      if ($dest_file | path exists) {
        # Collision: error with both sources
        let existing_target = (ls -l $dest_file | get target? | default "file")
        error make {msg: $"farm collision at ($path)/($basename): ($target) vs ($existing_target)"}
      }

      # Make relative symlink
      let rel_target = (make-relative $"($path)/($basename)" $"($file.name)")
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

  # mtimes are not set here: Nix normalises every store path to mtime 1. The version-derived
  # timestamp (epoch) is applied by mkfs.erofs -T when the image is made (image/erofs.nix).

  # Step 11: Verification
  log "verifying..."

  # 11a: No absolute symlink targets
  let abs_links = (^find $out -type l -print0 | ^xargs -0 -r -n1 sh -c 'readlink "$1" | grep -q "^/" && echo "$1"' -- | lines | where { $in != "" })
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
  let setuid = (^find $out -perm /6000 -type f | lines | where { $in != "" })
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
