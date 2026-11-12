# json-glib: JSON for GLib, which swtpm reads its TPM profiles with. A development tool's library,
# not part of an image
{ package, pkgs }:
package {
  name = "json-glib";
  uses = [ "meson" ];
  meson.defs = {
    introspection = "disabled";
    documentation = "disabled";
    nls = "disabled";
    man = false;
    # the JSON test suite's conformance cases, and tests installed beside the library
    conformance = false;
    installed_tests = false;
  };
  dependencies = [ pkgs.glib ];
  # json-glib-format and json-glib-validate: swtpm needs the library only, and the two programs
  # name the install prefix (bindtextdomain with the compiled-in locale directory, NLS or not)
  phases.after."meson.install" = {
    name = "no-tools";
    run = ''rm -rf $"($c.out)/bin"'';
  };
  platforms.os = [ "linux" ];
}
