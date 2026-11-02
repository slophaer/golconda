#!/bin/sh
# A small merge fixture: retain the typed lines, but let the fragment override BASE.
set -eu
shift # -m
cat "$@" > .config.new
if grep -q '^CONFIG_BASE=m$' .config.new; then
    grep -v '^CONFIG_BASE=y$' .config.new > .config
    rm .config.new
else
    mv .config.new .config
fi
