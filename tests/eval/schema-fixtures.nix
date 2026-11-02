# The Nix half of the paired schema fixtures also runs in the pure suite.
{
  check,
  sources,
  platform,
  ...
}:
map (fixture: check "schema fixture: ${fixture.name}" (fixture.nixAccepted == fixture.accepted)) (
  import ../schema { inherit sources platform; }
)
