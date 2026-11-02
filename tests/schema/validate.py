#!/usr/bin/env python3
"""Validate the public schema and compare JSON inputs with forced Nix results."""

import json
import sys

from jsonschema import Draft202012Validator


def main(schema_path, fixtures_path):
    with open(schema_path) as source:
        schema = json.load(source)
    with open(fixtures_path) as source:
        fixtures = json.load(source)
    Draft202012Validator.check_schema(schema)
    failures = 0
    for fixture in fixtures:
        target = schema
        if "definition" in fixture:
            target = {
                "$ref": f"#/$defs/{fixture['definition']}",
                "$defs": schema["$defs"],
            }
        errors = list(Draft202012Validator(target).iter_errors(fixture["value"]))
        schema_accepted = not errors
        expected = fixture["accepted"]
        nix_accepted = fixture["nixAccepted"]
        if schema_accepted != expected or nix_accepted != expected:
            failures += 1
            print(
                f"FAIL {fixture['name']}: expected={expected}, "
                f"schema={schema_accepted}, nix={nix_accepted}",
                file=sys.stderr,
            )
            for error in errors:
                print(f"  {error.json_path}: {error.message}", file=sys.stderr)
    print(f"{len(fixtures)} schema/Nix fixtures, {failures} failures")
    return int(failures != 0)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: validate.py SCHEMA.json FIXTURES.json")
    sys.exit(main(*sys.argv[1:]))
