# Registry Plugin Operation

## Classification
**Moonstone-specific** — Entirely concerned with producing artifacts in the Moonstone registry format (`package.toml`, recipe hashes, `publish.sh`).

## Purpose
Builds a Moonstone registry artifact from the export tree so it can be uploaded to `moonstone.sh`.

## Lifecycle Hooks

### `on_finalize(ctx)` (only hook)
- Creates `registry-artifact/` subdirectory inside the export output.
- Produces a gzipped tarball of the export tree (excluding `registry-artifact/` itself).
- Computes BLAKE3 hashes:
  - `blob_hash` for the tarball.
  - `recipe_hash` for the recipe metadata.
- Generates `package.toml` with:
  - `[package]` metadata (name, version, description, optional `[runtime_bundled]` block).
  - `[[artifacts]]` entry with URL, hash, size, ABI, materializer type.
  - `[[artifacts.provides]]` section:
    - `bin_lua` (if target is `any`, cross-platform Lua script).
    - `bin` (if native target, precompiled binary).
- Generates `publish.sh`, a curl-based script that uploads descriptor + blob to the registry API.
- The publish script expects `MOONSTONE_TOKEN` and optionally `MOONSTONE_PUBLISH_URL`.

## Key Outputs
- `registry-artifact/package.toml` — Moonstone registry descriptor.
- `registry-artifact/*.tar.gz` — compressed artifact blob.
- `registry-artifact/publish.sh` — upload script.

## Graph Position
```
[Export Tree] ─┬─→ tarball (gzip)
               │       ↓
               │   [blob_hash]
               │       ↓
               ├─→ package.toml (metadata + provides)
               │       ↓
               │   [recipe_hash]
               │       ↓
               └─→ publish.sh (curl upload)
```

## Moonstone Dependencies
- Moonstone recipe schema (`schema=moonstone.recipe.v0`).
- Moonstone artifact URL layout (`blobs/b3/<prefix>/<suffix>/<digest>.tar.gz`).
- Moonstone registry publish API (`/api/registry/v0/publish`).
- Moonstone package naming (`moonstone/ballad`).
- Moonstone `bin_lua` vs `bin` provide kinds.

## Generalization Potential
- **Low** — the output format is entirely Moonstone's registry protocol.
- Could be generalized to a "publisher" interface if other registries had a descriptor + blob upload model.
- The tarball + hash + metadata pattern is generic (like OCI, npm, Cargo), but the schema and API are Moonstone-specific.
