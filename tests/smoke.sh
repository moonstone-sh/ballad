#!/usr/bin/env sh
set -eu

moon run export -- . dist/ballad
test -f dist/ballad/file-graph.json
test -f dist/ballad/run.lua
