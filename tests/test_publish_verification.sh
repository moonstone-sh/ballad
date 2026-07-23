#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-publication.XXXXXX)

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR/registry/packages/moonstone/demo/1.2.3"
cat > "$WORK_DIR/package.toml" <<'TOML'
[package]
name = "moonstone/demo"
version = "1.2.3"
kind = "bin"
TOML
cat > "$WORK_DIR/registry/index.toml" <<'TOML'
[[package]]
name = "moonstone/demo"
version = "1.2.3"
descriptor = "packages/moonstone/demo/1.2.3/package.toml"
TOML
cp "$WORK_DIR/package.toml" "$WORK_DIR/registry/packages/moonstone/demo/1.2.3/package.toml"

MOONSTONE_REGISTRY_URL="file://$WORK_DIR/registry" \
MOONSTONE_PUBLICATION_ATTEMPTS=1 \
"$BALLAD_ROOT/scripts/wait-for-publication.sh" "$WORK_DIR/package.toml" > "$WORK_DIR/result.log"

grep -q 'Published moonstone/demo@1.2.3 is resolvable' "$WORK_DIR/result.log" || {
  cat "$WORK_DIR/result.log"
  echo "FAIL: publication verifier did not confirm the package"
  exit 1
}

echo "PASS: publication verification requires indexed descriptor availability"
