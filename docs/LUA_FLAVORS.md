# Lua flavors

Moonstone lets a package ship one file per Lua flavor for the same module:
`lexer@lua54.lua`, `lexer@luajit.lua`, `fs@lua51@windows.lua`, usually beside
an untagged `lexer.lua` fallback. `moon sync` projects the matching file as
`lexer.lua` in each consumer's environment. The rule is Moonstone's (spec:
Moonstone's `docs/PROJECT_ENVIRONMENT.md`, "Flavors"; Lua implementation:
`moonstone.variants`). This note covers what Ballad does with such files and
the one place Ballad itself uses them.

## Variant files in a build

- **Discovery and sinks copy them verbatim.** `layout.*`, `conventions.tree`,
  the directory sink and `moonstone.registry.*` treat `foo@lua54.lua` as an
  ordinary file. Selection is the consumer's `moon sync`, not Ballad's.
- **Module names drop the tags.** `ballad.path.module_name`, the dependency
  scanner behind the `nvim` plugin (`deps.build_internal_modules`), and the
  export filters of `layout` and `love` map `pkg/fs@lua54.lua` to module
  `pkg.fs`. Without this, a package that ships only variants of a module
  would see its own `require("pkg.fs")` reported as an unknown dependency.
- **`ballad.flavor`** (also `require("ballad").flavor`) exposes the pieces a
  plugin needs:
  - `parse(file_name)`: variant parts, nil for an ordinary file, false for a
    malformed one (`lexer@linux@lua54.lua`).
  - `module_file(path)`: `src/foo@lua54.lua` becomes `src/foo.lua`.
  - `parse_id(id)`: `"luajit-x86_64-linux"` becomes `{ family, level, os, arch }`.
  - `target()`: the flavor being built for, from `MOONSTONE_TARGET`, then the
    environment's `moonstone.target`, else nil.

  It defers to `moonstone.variants` when the environment provides it and
  otherwise uses a built-in copy of the same rule, so it works with Moonstone
  releases that predate flavors and outside Moonstone.

The watcher's glob validation (`^[%w%._%-%*/%?]+$`) rejects `@`, so a watch
cannot name a variant explicitly (`src/**/*@lua54.lua`). `src/**/*.lua` still
matches variant files, which is what a watch normally wants.

## Ballad's own variants

`src/ballad/crc32.lua` (the zip writer's checksum) is the only code in Ballad
whose implementation depends on the Lua flavor: LuaJIT has the `bit` library,
Lua 5.3+ has integer operators that older parsers cannot read, and PUC 5.1 has
neither. It ships as:

| file | used on |
|---|---|
| `crc32.lua` | fallback: picks `bit`, `bit32`, native operators (compiled from a string) or arithmetic at load time; runs everywhere |
| `crc32@luajit.lua` | LuaJIT: `bit` directly |
| `crc32@lua54.lua` | Lua 5.4: native operators directly |

All three return the same unsigned value, and the archive bytes are identical
to the previous `bit`-only writer (`tests/test_flavors.sh` checks the
checksums on every Lua on `PATH`). The rest of `archive.lua` is plain
arithmetic. As a result `love` packing also works when Ballad runs on PUC Lua
5.4 or 5.5, not only on LuaJIT.

Ballad's own `src/` tree loads `crc32.lua` unless `moonstone.variants` is
installed as a searcher. A Moonstone tool runs from its own `libexec` copy,
which `moon sync` does not project, so the installed Ballad tool also uses the
fallback. The variants pay off only where Ballad is a projected dependency.

**Not packaged yet.** Moonstone accepts `@` in artifact paths from 0.6.0.
Earlier versions fail `moon artifact create` with `InvalidVirtualPath`, and a
project that bundles Ballad's modules into its own artifact (a tool built with
`layout.exec`) would hit that with an older Moonstone. `partiture.lua`
therefore still excludes `src/**@*.lua`; drop the exclude once consumers are
expected to run Moonstone 0.6.0 or later.

## Requests for plugins that specialize per flavor (Quaver)

Ballad runs plugins in its own process, and native actions inherit its
environment, so `MOONSTONE_TARGET` already reaches both. Quaver's Ballad
adapter reads `MOONSTONE_TARGET` itself and selects files with the canonical
`moonstone.variants.parse`/`select` (see Quaver's
`docs/MOONSTONE_FLAVORS.md`, "Quaver implementation status"). That is the
right split. Ballad does not select variants, and `ballad.flavor` is not a
second selection rule. Its `parse` defers to `moonstone.variants` when present.
Two things remain:

1. **The cache key does not include the target.** Ballad's node cache key
   (`cache.compute_key`) covers plugin, method, options, controls and input
   hashes, but not the environment. A Quaver node whose output depends on
   `MOONSTONE_TARGET` gets a stale cache hit when only the target changes.
   Until Ballad handles this, the plugin should put the resolved target id in
   the node's options (`ballad.flavor.target()` returns it, or nil when
   Moonstone set none).
2. **Ballad should own that fix.** Put the resolved target id into every node
   key automatically, or let a plugin method declare the environment
   variables it reads. This was not done here because `cache.lua` and
   `pipeline.lua` have other work in progress.

Inventory note for Quaver: Ballad sinks and source sets pass `foo@lua54.lua`
through under its tagged path. Module names derived by Ballad drop the tags.
