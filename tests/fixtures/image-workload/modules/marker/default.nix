#! A marker file for the image tests (tests/eval/image-config.nix).
_: {
  name = "marker";
  impl = _: {
    files."/usr/lib/custom-marker" = {
      text = "custom workload\n";
      mode = "0644";
    };
  };
}
