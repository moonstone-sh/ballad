# Ballad Runtime Semantics

Ballad separates three runtime contexts to ensure reliable cross-platform exports and isolated tool execution.

1.  **Host Runtime**: The runtime environment currently executing Ballad and its plugins.
2.  **Project Runtime**: The runtime specified in the `moonstone.toml` of the project being exported.
3.  **Export Runtime**: The specific runtime policy defined for the resulting artifact.

## Core Integration
*   **Moonstone Isolation**: When you execute a tool like Ballad via `moon exec`, Moonstone identifies the tool's specific runtime requirements and generates an isolated shim. This ensures Ballad always runs with its required interpreter (e.g., LuaJIT), even if your project is configured for a different version (e.g., Lua 5.4).
*   **Ballad Portability**: Ballad uses Moonstone metadata to resolve and bundle exactly what is needed for a target platform.

## Tool Closure Inputs

`moonstone.tool(project, { name = "tool-name" })` introduces a fourth, derived
context: the selected executable tool closure. Moonstone resolves that closure
from the synchronized lockfile and records its executable paths, Lua module
paths, native module paths, and compatible runtime in the tool's private scope.

Ballad consumes those paths as source assets. It does not solve the tool's
dependencies again and does not merge them into the host application's runtime
dependency set. `layout.exec(tool, ...)` can then export the selected closure as
a runnable tool distribution.

## Export Strategies

### Agnostic Export
Generated when the `runtime` plugin is omitted. 
*   **Behavior**: Exports portable Lua source code.
*   **Metadata**: `target = "any"`.
*   **Requirement**: Declares an external `runtime` dependency in the manifest. Moonstone will provide this runtime during installation on the end-user's machine.

### Standalone Export
Generated when the `runtime` plugin is included.
*   **Behavior**: Bundles a concrete Moonstone runtime artifact into the export (under `runtime/`).
*   **Metadata**: Specific target platform (e.g., `linux-x86_64`) and a `[runtime_bundled]` section for full provenance.
*   **Requirement**: Zero external dependencies; uses the bundled interpreter.

---

> [!WARNING]
> `target = "any"` means **platform-agnostic**, not runtime-agnostic. 
> A package can be compatible with any OS/Arch while still strictly requiring a specific runtime like `luajit@2.1.0`.
