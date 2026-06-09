# Runtime Plugin Operation

## Classification
**Moonstone-specific** — Deeply tied to the Moonstone runtime store, artifact resolution, and the `moon runtime path` CLI.

## Purpose
Bundles the Lua/LuaJIT runtime itself into the export so the artifact is fully self-contained (standalone mode). No system Lua interpreter is required at the destination.

## Lifecycle Hooks

### `on_init(ctx)`
- Determines target platform:
  - From plugin params (`target`), or
  - From host target (`ctx.host.target`).
- Determines runtime spec:
  - From plugin params (`runtime`), or
  - From project runtime (`ctx.project.runtime`).
- **Resolves runtime artifact** via `ctx.moonstone:get_runtime_artifact(query)`:
  - Query: `{ name, version, target }`.
  - If the target matches the host and the runtime spec matches the host runtime, uses `ctx.moonstone.get_project_runtime()` instead (local dev fast-path).
- If resolution fails, the export **fails immediately** with a diagnostic message.
- Sets `ctx.runtime_provision`:
  - `files_root`: path to the runtime artifact's `files/` directory in the Moonstone store.
  - `interpreter_rel`: relative path to the interpreter binary inside `files/`.
  - `dest_dir`: `"runtime"` (where files will land in the export).
- Updates `ctx.export.bundled_runtime` and `ctx.interpreter` so the launcher uses the bundled binary.

### `on_finalize(ctx)`
- Copies **all** files from the resolved runtime artifact (`files/`) into the export under `runtime/`.
- This includes `bin/`, `lib/`, `share/`, `include/`, etc.
- Each file is emitted via `ctx.emit_file()` so it appears in the file graph.

## Key Outputs
- `runtime/` directory containing the full Lua/LuaJIT runtime.
- `ctx.interpreter` updated to `"$ROOT/runtime/..."` path.

## Graph Position
```
[Moonstone Store] → get_runtime_artifact → [Runtime Artifact]
                                               ↓
                                         on_finalize
                                               ↓
                                        [runtime/ tree]
                                               ↓
                                         [bin/ launcher]
                                              (uses bundled interpreter)
```

## Moonstone Dependencies
- `ctx.moonstone:get_runtime_artifact(query)` — calls `moon runtime path <spec> --json`.
- `ctx.moonstone.get_project_runtime()` — reads `.moonstone/env/runtime.json`.
- Expects Moonstone store layout (`store/<hash>/files/...`).

## Generalization Potential
- **Low** without significant abstraction.
- Could be generalized to "bundle any runtime artifact from a store" if the store API were pluggable.
- The concept of "self-contained export with bundled interpreter" is general, but the resolution mechanism is Moonstone-specific.
