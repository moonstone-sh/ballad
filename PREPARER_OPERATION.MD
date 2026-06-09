# Preparer Plugin Operation

## Classification
**General / Reusable** — Not Moonstone-specific. Could be reused in any Lua project export pipeline.

## Purpose
Transforms a flat project tree into a portable `libexec/<bin>/` package structure and generates a launcher shell script that makes the export relocatable.

## Lifecycle Hooks

### `on_init(ctx)`
- Reads `ctx.manifest.package.name` (e.g. `moonstone/ballad`).
- Derives `ctx.preparer`:
  - `bin_name`: trailing segment of the package name (e.g. `ballad`).
  - `libexec_root`: target directory for all exported files (e.g. `libexec/ballad`).

### `on_add_file(ctx, task)`
- Rewrites file destinations so the exported tree is relocatable.
- **Project files** (`kind == "project"`): moved under `libexec/<bin>/<relative-src>`.
- **Package files** (`kind == "package"`): moved under `libexec/<bin>/<original-dest>`.

### `on_finalize(ctx)`
- Generates a portable shell launcher at `bin/<bin_name>`.
- The launcher:
  1. Computes `ROOT` from its own location (`dirname "$0"`/..).
  2. Exports `LUA_PATH` pointing to `libexec/<bin>/lua/` and `libexec/<bin>/src/`.
  3. Exports `LUA_CPATH` pointing to `libexec/<bin>/lib/`.
  4. `exec <interpreter> "libexec/<bin>/<main>" "$@"`.
- The interpreter is resolved from (in order):
  1. Plugin params (`interpreter`).
  2. Bundled runtime (`ctx.export.runtime`).
  3. Plain `lua` fallback.
- The launcher is made executable (`chmod +x`).

## Key Outputs
- `bin/<bin_name>` — executable shell launcher script.

## Graph Position
```
[Project Source] → on_add_file (rewrite dest) → [libexec/<bin>/ tree]
                                          ↓
                                      on_finalize
                                          ↓
                                   [bin/<bin> launcher]
```

## Generalization Potential
- The `libexec/` convention is a Unix standard (Homebrew, Git, etc.).
- The launcher pattern works for any interpreted language (Python, Ruby, Node).
- To generalize further: accept arbitrary interpreter templates or runtime environment blocks.
