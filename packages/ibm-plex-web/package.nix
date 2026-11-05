# ibm-plex-web: the IBM Plex fonts the console's web pages use, as golcondad serves them
# (console/daemon): Plex Sans 400, 500 and 600 and Plex Mono 400 and 500, Latin subset, WOFF2,
# about 100 KB, with their licence (SIL Open Font License 1.1). From Fontsource's npm
# packages, which carry the subsets ready-made. Data only; not part of an image.
{ package, sources }:
package {
  name = "ibm-plex-web";
  phases = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        let dir = $"($c.out)/share/fonts/ibm-plex"
        mkdir $dir
        let want = [
          [$c.src "ibm-plex-sans" [400 500 600]]
          [$env.GOLCONDA_PLEX_MONO "ibm-plex-mono" [400 500]]
        ]
        for w in $want {
          for weight in $w.2 {
            ^cp $"($w.0)/files/($w.1)-latin-($weight)-normal.woff2" $dir
          }
          ^cp $"($w.0)/LICENSE" $"($dir)/($w.1).LICENSE"
        }
      '';
    }
  ];
  env.GOLCONDA_PLEX_MONO = "${sources.fetch "mono"}";
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
  bin = [ ];
  tests.version = false;
}
