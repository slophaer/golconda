# dash: the POSIX /bin/sh of Golconda images (the seed also uses this source)
{ package }:
package {
  name = "dash";
  uses = [ "autotools" ];
  autotools.flags = [
    "--with-libedit=no" # no line editing: not an interactive shell
  ];
  tests.version = false; # dash has no --version
  bin = [ "dash" ];
}
