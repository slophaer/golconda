#!/usr/bin/env python3
"""Check the public schema against JSON Schema 2020-12's metaschema (checks.schema-metaschema).

Python's jsonschema implements the whole draft: it is the outside opinion on the schema that
editors and other tools read. The fixtures run through the console's own validator instead
(checks.schema-parity, console/core/examples/schema-parity.rs).
"""

import json
import sys

from jsonschema import Draft202012Validator


def main(schema_path):
    with open(schema_path) as source:
        schema = json.load(source)
    Draft202012Validator.check_schema(schema)
    print("the schema is valid JSON Schema 2020-12")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: metaschema.py SCHEMA.json")
    main(sys.argv[1])
