#!/usr/bin/env python3
"""Validate CycloneDX 1.5 documents against the vendored schema (checks.sbom-schema).

usage: validate.py SCHEMA_DIR --valid FILE... --invalid FILE...

SCHEMA_DIR holds bom-1.5.schema.json and the two schemas it refers to by relative $ref
(spdx.schema.json, jsf-0.82.schema.json: tests/fixtures/cyclonedx). They are registered by their
$id, so no reference is fetched. A --valid file must pass; an --invalid file must fail, so that a
validator which accepts everything fails the check too."""

import argparse
import json
import sys
from pathlib import Path

from jsonschema import Draft7Validator, FormatChecker
from referencing import Registry, Resource

SCHEMAS = ["bom-1.5.schema.json", "spdx.schema.json", "jsf-0.82.schema.json"]


def load(path):
    with open(path) as source:
        return json.load(source)


def validator(schema_dir):
    schemas = {name: load(Path(schema_dir) / name) for name in SCHEMAS}
    registry = Registry().with_resources(
        (schema["$id"], Resource.from_contents(schema)) for schema in schemas.values()
    )
    bom = schemas["bom-1.5.schema.json"]
    Draft7Validator.check_schema(bom)
    return Draft7Validator(bom, registry=registry, format_checker=FormatChecker())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("schema_dir")
    parser.add_argument("--valid", nargs="*", default=[])
    parser.add_argument("--invalid", nargs="*", default=[])
    args = parser.parse_args()
    check = validator(args.schema_dir)
    failures = 0
    for path in args.valid:
        errors = list(check.iter_errors(load(path)))
        for error in errors[:10]:
            print(f"FAIL {path}: {error.json_path}: {error.message[:300]}", file=sys.stderr)
        failures += bool(errors)
    for path in args.invalid:
        errors = list(check.iter_errors(load(path)))
        if errors:
            print(f"ok   {path}: refused: {errors[0].json_path}: {errors[0].message[:120]}")
        else:
            print(f"FAIL {path}: accepted, but it must not be", file=sys.stderr)
            failures += 1
    print(f"{len(args.valid)} documents that must be valid, {len(args.invalid)} that must not; "
          f"{failures} failures")
    return int(failures != 0)


if __name__ == "__main__":
    sys.exit(main())
