let
  golconda = import (
    builtins.fetchTarball {
      url = "https://github.com/slophaer/golconda/archive/<rev>.tar.gz";
      sha256 = "<the NAR hash of the unpacked tree>";
    }
  );
in
golconda.lib.mkSystem {
  config = ./server.toml;
  system = "x86_64-linux";
}
