# popt: command line option parsing library
{ package }:
package {
  name = "popt";
  uses = [ "autotools" ];
  autotools.flags = [
    "--disable-nls" # no gettext
    "--sysconfdir=/etc" # system-wide config lives in /etc/popt and /etc/popt.d
  ];
  tests.run = true;
  bin = [ ]; # library only
}
