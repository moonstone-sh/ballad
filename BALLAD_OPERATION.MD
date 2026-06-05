# Ballad Export Pipeline — Plugin Operations

Ballad is a deterministic Lua project exporter for Moonstone. Its export pipeline is driven by three plugins that hook into a shared export lifecycle: `on_init`, `on_add_file`, and `on_finalize`.

---

## 1. Preparer Plugin (`src/ballad/plugins/preparer.lua`)

**Purpose:** Transforms the flat project tree into a portable `libexec/<bin>/` package structure and generates the launcher shell script.

### `on_init(ctx)`
- Reads `ctx.manifest.package.name` (e.g. `moonstone/ballad`).
- Sets up `ctx.preparer`:
  - `bin_name`: the trailing segment of the package name (e.g. `ballad`).
  - `libexec_root`: the directory under which all exported files will live (e.g. `libexec/ballad`).

### `on_add_file(ctx, task)`
- Rewrites file destinations so the exported tree is relocatable.
- For `kind == "project"`: the file goes under `libexec/<bin>/<relative-src>`.
- For `kind == "package"`: the file goes under `libexec/<bin>/<original-dest>`.

### `on_finalize(ctx)`
- Generates a portable shell launcher at `bin/<bin_name>` with:
  - `LUA_PATH` pointing to `libexec/<bin>/lua/` and `libexec/<bin>/src/`.
  - `LUA_CPATH` pointing to `libexec/<bin>/lib/`.
  - `exec <interpreter> libexec/<bin>/<main> "$@"`.
- The interpreter is sourced from plugin params, the bundled runtime, or falls back to plain `lua`.

**Key output:** `bin/ballad` launcher script.

---

## 2. Runtime Plugin (`src/ballad/plugins/runtime.lua`)

**Purpose:** Bundles the Lua runtime itself into the export so the artifact is fully self-contained (standalone mode).

### `on_init(ctx)`
- Resolves the runtime artifact from the Moonstone store using `ctx.moonstone:get_runtime_artifact(...)`.
- If the runtime cannot be found, the export **fails immediately** with a clear error.
- Sets `ctx.runtime_provision`:
  - `files_root`: path to the runtime artifact's `files/` directory.
  - `interpreter_rel`: relative path to the interpreter inside `files/`.
- Updates `ctx.export.bundled_runtime` and `ctx.interpreter` so the launcher uses the bundled binary.

### `on_finalize(ctx)`
- Copies **all** files from the resolved runtime artifact (`files/`) into the export under `runtime/`.
- This includes `bin/`, `lib/`, `share/`, `include/`, etc.

**Key output:** `runtime/` directory containing the full Lua/LuaJIT runtime.

---

## 3. Registry Plugin (`src/ballad/plugins/registry.lua`)

**Purpose:** Builds a Moonstone registry artifact from the export tree so it can be uploaded to `moonstone.sh`.

### `on_finalize(ctx)`
- Creates a `registry-artifact/` subdirectory inside the export output.
- Produces a gzipped tarball of the export tree (excluding `registry-artifact/` itself).
- Computes BLAKE3 hashes:
  - `blob_hash` for the tarball.
  - `recipe_hash` for the recipe metadata.
- Generates `package.toml` with:
  - `[package]` metadata (name, version, description).
  - `[runtime_bundled]` block (if the runtime plugin bundled a runtime).
  - `[[artifacts]]` entry with URL, hash, size, and ABI.
  - `[[artifacts.provides]]` section:
    - `bin_lua` (if target is `any`, cross-platform) or `bin` (if native).
- Generates `publish.sh`, a curl-based script that uploads the descriptor + blob to the registry.

**Key outputs:** `registry-artifact/package.toml`, `registry-artifact/*.tar.gz`, `registry-artifact/publish.sh`.

---

## Plugin Interaction Diagram

```
User runs:  moon exec -- ballad . dist/ballad [--layout love] [--main src/main.lua]

        ┌─────────────────────────────────────────────┐
        │           runtime.on_init()                 │
        │  Resolve runtime artifact from store        │
        │  → sets ctx.interpreter to bundled path     │
        └─────────────────────────────────────────────┘
                          │
        ┌─────────────────────────────────────────────┐
        │          preparer.on_init()                 │
        │  Set libexec_root, bin_name                 │
        └─────────────────────────────────────────────┘
                          │
        ┌─────────────────────────────────────────────┐
        │  File collection phase                      │
        │  Each file passes through:                  │
        │     preparer.on_add_file()                │
        │     → rewrites dest under libexec/<bin>/   │
        └─────────────────────────────────────────────┘
                          │
        ┌─────────────────────────────────────────────┐
        │          runtime.on_finalize()              │
        │  Copy runtime files into export/runtime/    │
        └─────────────────────────────────────────────┘
                          │
        ┌─────────────────────────────────────────────┐
        │         preparer.on_finalize()              │
        │  Generate launcher script at bin/<bin>       │
        └─────────────────────────────────────────────┘
                          │
        ┌─────────────────────────────────────────────┐
        │         registry.on_finalize()                │
        │  Create tarball + package.toml + publish.sh │
        └─────────────────────────────────────────────┘
```

---

## Exported Directory Layout (lua layout)

```
dist/ballad/
├── bin/ballad          ← launcher script (preparer)
├── libexec/ballad/
│   ├── src/
│   │   └── main.lua
│   ├── lua/
│   │   └── dkjson.lua
│   └── lib/
├── runtime/            ← bundled LuaJIT (runtime)
│   ├── bin/
│   ├── lib/
│   └── share/
├── file-graph.json
└── registry-artifact/  ← (registry)
    ├── package.toml
    ├── ballad-*.tar.gz
    └── publish.sh
```

---

## Notes

- The **Preparer's** launcher script is what makes the export portable. It hardcodes `LUA_PATH` and `LUA_CPATH` relative to its own location.
- The **Runtime** plugin is optional. If omitted, the launcher expects a system `lua` or `luajit` to be available.
- The **Registry** plugin only runs on explicit `--to-registry` or when triggered by the build script. It is not part of the default export flow.
