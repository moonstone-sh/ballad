# Windows Watcher Helper Protocol

Ballad owns watcher declaration, graph-derived source patterns, manifest
generation, and the user-facing diagnostics. A native `ballad-watch` helper
owns Windows file notifications, direct process spawning, cancellation, and
cleanup. This repository contains the helper source at
`native/ballad-watch`, but it does **not** yet package or provision it as a
Moonstone helper artifact.

## Building the native source

From `native/ballad-watch`:

```text
zig build
zig build test
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

The last command cross-builds the Windows executable from macOS or Linux.
Build output is local only; it is not a Moonstone provision.

## Provisioning

On Windows Ballad runs exactly:

```text
moon provision resolve ballad-watch --json
```

The helper must be an already synchronized Moonstone `helper` provision named
`ballad-watch`; resolution is offline-only. Ballad never uses a locally built
binary or downloads one as a fallback. The response must be:

```json
{
  "contract": "moonstone:tool-resolve:v1",
  "path": "C:/.../ballad-watch.exe",
  "version": "...",
  "digest": "b3:...",
  "source": "project"
}
```

Ballad invokes the resolved executable without a shell:

```text
ballad-watch --manifest <absolute-path-to-manifest>
```

On a zero exit, stdout must contain exactly one JSON response:

```json
{
  "contract": "ballad:watcher-result:v1",
  "status": "completed",
  "mode": "once"
}
```

For a daemon stopped through its normal cancellation path, use
`"status": "stopped", "mode": "daemon"`. Reserve stdout for this response;
write logs and diagnostics to stderr. This acknowledgement prevents an older
binary that ignores `--manifest` from being accepted as a watcher helper.

If resolution fails, returns another contract, or the executable rejects the
manifest, Ballad reports that the helper is absent or too old. Install a helper
implementing `ballad:watcher:v1` as a project helper dependency, then run
`moon sync`. Ballad deliberately does not download, emulate, or replace it.

## Manifest `ballad:watcher:v1`

Ballad writes canonical JSON at `.ballad/watchers/<node>.windows.json` (or the
declared `state_dir`). Object keys are sorted and all ordered lists retain the
partiture declaration order.

```json
{
  "contract": "ballad:watcher:v1",
  "node": "node_3",
  "mode": "daemon",
  "cwd": ".",
  "interval": 0.5,
  "debounce": 0.1,
  "initial": {
    "label": "bootstrap",
    "outputs": ["dist/app"],
    "action": {
      "id": "bootstrap",
      "argv": ["tool.exe", "--build"],
      "cwd": ".",
      "env": {},
      "inputs": [],
      "outputs": ["dist/app"],
      "cacheable": true
    }
  },
  "reactions": [
    {
      "label": "sources",
      "source_nodes": ["node_1"],
      "inputs": ["src/**/*.lua", "src/*.lua"],
      "outputs": ["dist/app"],
      "action": { "id": "rebuild", "argv": ["tool.exe"] }
    }
  ],
  "output_exclusions": ["dist/app"]
}
```

The real action objects contain every field shown above. `argv` is an argv
vector: element zero is the executable and subsequent elements are literal
arguments. The helper must execute it with a direct Windows process API, not
`cmd.exe`. `env` is an additive string-to-string environment map. `cwd` is
relative to the manifest `cwd` when it is relative. `cacheable`, `inputs`,
`outputs`, and an optional `toolchain_fingerprint` are supplied so a helper can
preserve Ballad action identity without evaluating a shell command.

`source_nodes` and normalized `inputs` are derived from the same Ballad source
nodes recorded as graph inputs. The helper watches only `inputs`. It must
exclude a path matching any `output_exclusions` entry, including descendants of
an excluded directory, before debounce and reaction selection. The exclusions
combine every declared watcher-step output and every native-action output in
first-declaration order; this prevents a reaction from retriggering itself.

## Required behavior

1. Validate `contract == "ballad:watcher:v1"`; reject unknown versions.
2. Run `initial.action` exactly once, before installing change reactions.
3. In `mode: "once"`, run only that initial action (if present), do not watch,
   then exit zero. This is Ballad's existing once semantic.
4. In `mode: "daemon"`, debounce each reaction independently and execute
   matching reactions in manifest order. Do not run reactions at startup.
5. Execute only `action.argv`; no shell text is present or permitted. A failed
   action must make the helper exit nonzero with a useful stderr diagnostic.
6. On Ctrl-C, console close, termination, or normal shutdown, stop accepting
   events, wait for any started child process, and clean up helper-owned watcher
   resources before exiting. Shutdown must be idempotent; child process and
   handle cleanup must be bounded so Ballad does not leave a detached watcher.

`before`, `effect`/`command`, `cleanup`, `task.native.cmd`, and
`task.native.toolchain.command` are legacy shell surfaces. Ballad rejects them
on Windows before resolving or launching the helper. POSIX continues to use
its shell supervisor unchanged.
