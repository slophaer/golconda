# Paired input fixtures. Force mkSystem composition, not only loader name checks.
# JSON cannot encode Nix derivations or functions; package overrides are outside this test.
{
  sources ? import ../../nix/sources.nix,
  platform ? "x86_64-linux",
}:
let
  inherit (builtins)
    all
    attrNames
    deepSeq
    fromJSON
    fromTOML
    readFile
    tryEval
    ;
  harness = import ../eval/harness.nix { inherit sources platform; };
  inherit (harness) configLib;
  libraryTypes = {
    inherit (harness.v) var adminVar;
    inherit (harness.fr) fragment file link;
    inherit (harness.a) credentialRef envOp;
  };
  configAccepted =
    value:
    # optionError also rejects /pkgs; checkOptions permits Nix's internal binding.
    all (path: configLib.optionError path value.${path} == null) (attrNames value)
    # tryEval cannot catch missing-attribute evaluator errors from required identity fields.
    && value ? "/system"
    && value."/system" ? name
    && value."/system" ? version
    && (tryEval (
      let
        result =
          (import ../../lib/system.nix {
            config = value;
            inherit sources platform;
            system = platform;
          }).composed;
      in
      deepSeq [
        result.name
        result.version
        result.files
        result.units
        result.links
        result.tmpfiles
      ] true
    )).success;
  withResult =
    fixture:
    fixture
    // {
      nixAccepted =
        if (fixture.definition or null) == "updateSource" then
          configAccepted {
            "/system" = {
              name = "test";
              version = "20261031.1";
              updateSource = fixture.value;
            };
          }
        else if fixture ? definition then
          libraryTypes.${fixture.definition}.verify fixture.value == null
        else
          configAccepted fixture.value;
    };
  # bad.toml is the intentionally invalid example; every other example must pass.
  examples =
    map
      (name: {
        name = "example ${name}";
        accepted = name != "bad.toml";
        value = fromTOML (readFile (../../examples + "/${name}"));
      })
      (
        builtins.filter (name: builtins.match ".*\\.toml" name != null) (
          attrNames (builtins.readDir ../../examples)
        )
      );
in
map withResult ((fromJSON (readFile ./fixtures.json)) ++ examples)
