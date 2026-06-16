#!/usr/bin/env sh
set -eu

moon run play
test -f dist/ballad/file-graph.json
test -f dist/ballad/bin/ballad
