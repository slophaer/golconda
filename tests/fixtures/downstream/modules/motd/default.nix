#! A downstream module for the tests: the message of the day.
{ types, ... }:
{
  name = "motd";

  options.text = {
    type = types.string;
    default = "Welcome to Golconda\n";
    description = "The message of the day (/usr/lib/motd).";
  };

  impl =
    { options, ... }:
    {
      files."/usr/lib/motd" = {
        inherit (options) text;
        mode = "0644";
      };
    };
}
