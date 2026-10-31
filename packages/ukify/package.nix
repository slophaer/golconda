# ukify: systemd's UKI builder, as a Golconda build-time package. The image's systemd is built
# with ukify=disabled (a Python tool has no place in the image), so this takes src/ukify/ukify.py
# from systemd's source tree, renders the two jinja2 version fields meson would, and wraps it in
# a bin/ukify that puts pefile on sys.path (python.nu's pattern: relative to the script).
# Needs at run time: python3 (a dependency, found by the launcher) and systemd's lib/systemd for
# systemd-measure and systemd-sbsign (`ukify --tools <dir>`), plus the stub (`--stub`).
{ package, pkgs }:
package {
  name = "ukify";
  dependencies = [
    pkgs.cpython
    pkgs.python-pefile
  ];
  phases = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        mkdir $"($c.out)/lib/ukify" $"($c.out)/bin"
        open --raw $"($c.src)/src/ukify/ukify.py"
          | str replace "{{PROJECT_VERSION}}" ($c.spec.version | split row "." | first)
          | str replace "{{VERSION_TAG}}" $c.spec.version
          | save -f $"($c.out)/lib/ukify/ukify.py"
        let pefile = (dep-root python-pefile "ukify imports pefile")
        let site = (glob $"($pefile)/lib/python3*/site-packages" | first)
        let rel = $"../../($site | path relative-to $env.NIX_STORE)"
        [
          "#!/usr/bin/env python3"
          "import os, sys"
          "here = os.path.dirname(os.path.realpath(__file__))"
          $"sys.path[0:0] = [os.path.join\(here, p\) for p in ['../lib/ukify', '($rel)']]"
          "import ukify"
          "ukify.main()"
        ] | str join "\n" | save -f $"($c.out)/bin/ukify"
        ^chmod 755 $"($c.out)/bin/ukify"
      '';
    }
  ];
  bin = [ "ukify" ];
  tests.version = "--version";
  platforms.os = [ "linux" ];
}
