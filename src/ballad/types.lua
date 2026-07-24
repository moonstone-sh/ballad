---@meta

---Ballad's public API. Define a partiture DAG with core `p.source.*` inputs,
---plugin transforms, and explicit `p.sink.*` outputs.
---@class Ballad
---@field partiture fun(fn: fun(p: PipelineContext)): fun(p: PipelineContext) Define a partiture callback.
---@field plugins BalladBuiltinPlugins Built-in plugin contracts for typed `p:use(ballad.plugins.*)` calls.

---@class BalladBuiltinPlugins
---@field moonstone MoonstonePluginContract Reads Moonstone project metadata.
---@field layout LayoutPluginContract Builds portable Lua layouts.
---@field love LovePluginContract Builds LÖVE layouts and `.love` archives.
---@field registry RegistryPluginContract Builds Moonstone registry descriptors/artifacts.
---@field nvim NvimPluginContract Builds Neovim plugin layouts and metadata.
---@field runtime RuntimePluginContract Bundles selected Moonstone runtimes.
---@field watcher WatcherPluginContract Runs ordered, debounced, signal-aware file-watch reactions.
---@field lua LuaPluginContract Reserved Lua compile/check transforms.
---@field input BalladInputPlugins First-party input providers.

---@class BalladInputPlugins
---@field moonstone MoonstoneInputPluginContract Resolve Moonstone lockfile packages through `moon store query`.

---@class PluginContract: table
---@field name string Fully-qualified plugin name.
---@field version string Plugin contract version.
---@field methods table<string, table> Method contract metadata consumed by Ballad.

---@class MoonstonePluginContract: PluginContract
---@field __ballad_type? 'moonstone'
---@class LayoutPluginContract: PluginContract
---@field __ballad_type? 'layout'
---@class LovePluginContract: PluginContract
---@field __ballad_type? 'love'
---@class RegistryPluginContract: PluginContract
---@field __ballad_type? 'registry'
---@class NvimPluginContract: PluginContract
---@field __ballad_type? 'nvim'
---@class RuntimePluginContract: PluginContract
---@field __ballad_type? 'runtime'
---@class WatcherPluginContract: PluginContract
---@field __ballad_type? 'watcher'
---@class LuaPluginContract: PluginContract
---@field __ballad_type? 'lua'
---@class MoonstoneInputPluginContract: PluginContract
---@field __ballad_type? 'input.moonstone'

---@alias BalladDependencyRole 'runtime'|'tool'|'dev'|'helper'|'peer'|'optional'
---@alias BalladLuaAbi '5.1'|'5.2'|'5.3'|'5.4'|'lua51'|'lua52'|'lua53'|'lua54'|'lua-5.1'|'lua-5.2'|'lua-5.3'|'lua-5.4'

---@class NodeHandle: table
---@field _id? string Internal graph node id.
---@field _graph? Graph Internal graph reference.
---@field [string] any Eager metadata exposed by prepare hooks.
---@field id? fun(self: NodeHandle): string Return graph node id.
---@field metadata? fun(self: NodeHandle): table|nil Return graph node metadata.

---A Moonstone project handle. Fields are available immediately after `moonstone.project(...)`.
---@class MoonstoneProject: NodeHandle
---@field name string Package name from `[package].name`.
---@field version string Package version from `[package].version`.
---@field root string|nil Project root path.
---@field runtime MoonstoneRuntime|nil Hydrated active runtime metadata.
---@field runtime_spec string|nil Runtime spec, e.g. `lua@5.4` or `love@11.5`.
---@field lua_abi BalladLuaAbi Active Lua ABI.
---@field registry_name string|nil Registry package name override.
---@field description string Project description.
---@field packages MoonstoneResolvedPackage[]|nil Runtime package records enriched by `ballad.plugins.input.moonstone`.

---@class MoonstoneRuntime
---@field id string Runtime spec, e.g. `lua@5.4.7`.
---@field name string Runtime command/package name, e.g. `lua` or `luajit`.
---@field version string Runtime version.
---@field lua_abi BalladLuaAbi Active Lua ABI normalized for consumers.
---@field target string|nil Runtime artifact target.
---@field artifact_hash string|nil Runtime artifact hash.
---@field artifact_path string|nil Absolute local store artifact path.
---@field manifest_path string|nil Store manifest path for the runtime artifact.
---@field source_payload string|nil Runtime source payload path relative to the artifact root.
---@field source_payload_path string|nil Absolute runtime source payload path in the local store.
---@field source_kind string|nil Runtime source payload kind.
---@field source_hash string|nil Runtime source hash when available.
---@field bin table<string,string>|nil Runtime binaries relative to artifact root, e.g. `files/bin/lua`.
---@field lib table<string,string>|nil Runtime library paths relative to artifact root.
---@field include string|nil Runtime include path relative to artifact root.
---@field env table|nil Moonstone environment metadata.

---@class MoonstoneStoreWarning
---@field code string Machine-readable warning code.
---@field message string Human-readable warning message.

---@class MoonstoneResolvedPackage
---@field name string Package name from `moonstone.lock`.
---@field version string Package version from `moonstone.lock`.
---@field kind string Package kind from `moonstone.lock`.
---@field resolver string|nil Package resolver, e.g. `moonstone`, `rocks`, `path`, or `link`.
---@field roles BalladDependencyRole[]|nil Dependency roles recorded in `moonstone.lock`.
---@field artifact_hash string Artifact hash selected by `moonstone.lock`.
---@field source_hash string|nil Source payload hash when available.
---@field recipe_hash string|nil Recipe hash when available.
---@field source string|nil Upstream source URL or resolver source identifier.
---@field source_kind string|nil Source payload kind, e.g. `luarocks_src_rock`, `upstream_archive`, or registry artifact kind.
---@field source_payload string|nil Relative source payload path inside the local artifact store entry.
---@field source_payload_path string|nil Absolute local path to the source payload, from `moon store query`.
---@field rockspec string|nil Upstream rockspec URL when available.
---@field rockspec_hash string|nil Rockspec BLAKE3 hash when available.
---@field rockspec_payload string|nil Relative rockspec payload path inside the local artifact store entry.
---@field rockspec_payload_path string|nil Absolute local path to the rockspec payload, from `moon store query`.
---@field artifact_path string|nil Absolute local store artifact path, from `moon store query`.
---@field manifest_path string|nil Absolute local store manifest path, from `moon store query`.
---@field store_warnings MoonstoneStoreWarning[]|nil Non-fatal query/path diagnostics.
---@field store_query table|nil Raw `moon store query --json` result for advanced consumers.

---A generic asset-producing transform handle.
---@class AssetNode: NodeHandle

---A layout asset set suitable for `p.sink.directory`, `registry.package`, or another transform.
---@class LayoutNode: AssetNode

---A single artifact-producing transform handle suitable for `p.sink.artifact`.
---@class ArtifactNode: AssetNode

---A registry artifact directory containing `package.toml`, tarball(s), and publish script(s).
---@class RegistryArtifactNode: ArtifactNode

---@class Asset
---@field id string
---@field kind string Asset kind such as `file`, `generated`, `project`, `package`, `files`, `registry`, `runtime`, or `sink`.
---@field source_path string|nil Source file path on disk.
---@field virtual_path string|nil Path inside the pipeline layout.
---@field output_path string|nil Materialized output path after sinks/native tasks.
---@field content string|nil Generated file content.
---@field generated boolean|nil True when content was generated by Ballad.
---@field metadata table|nil Plugin-specific metadata.

---@class AssetSet
---@field assets Asset[]
---@field add fun(self: AssetSet, asset: Asset)
---@field merge fun(self: AssetSet, other: AssetSet): AssetSet
---@field filter fun(self: AssetSet, predicate: fun(asset: Asset): boolean): AssetSet
---@field count fun(self: AssetSet): integer

---@class NativeTaskOptions
---@field id string|nil Stable task id for diagnostics.
---@field tool string Executable name or absolute/relative path.
---@field args string[]|nil Command arguments.
---@field cwd string|nil Working directory, defaults to `.`.
---@field env table<string,string>|nil Extra environment variables.
---@field inputs string[]|nil Declared input paths for cache/scheduling.
---@field outputs string[] Declared output paths; Ballad validates them.
---@field cacheable boolean|nil Whether task can be cached, defaults to true.
---@field parallel_safe boolean|nil Whether task may run concurrently, defaults to true.
---@field description string|nil Human-readable task description.

---@class PipelineContext
---@field source PipelineSourceNamespace Core source nodes.
---@field sink PipelineSinkNamespace Core sink nodes; every partiture must declare at least one.
---@field files fun(self: PipelineContext, pattern_or_patterns: string|string[]): AssetSet Legacy direct file collection using Lua patterns.
---@field asset fun(self: PipelineContext, path: string, opts: AssetOptions|nil): Asset Create an asset for an existing file.
---@field generated fun(self: PipelineContext, path: string, content: string, opts: GeneratedAssetOptions|nil): Asset Create an in-memory generated asset.
---@field node fun(self: PipelineContext, plugin: string, method: string, inputs: NodeHandle[]|nil, opts: table|nil): NodeHandle Create a raw transform node.
---@field metadata fun(self: PipelineContext, key: string, value: any) Attach run metadata.
---@field warn fun(self: PipelineContext, message: string) Emit a non-fatal warning.
---@field fail fun(self: PipelineContext, message: string) Abort with a user-facing diagnostic.
---@field native_task fun(self: PipelineContext, opts: NativeTaskOptions): AssetSet Declare subprocess work.

---@class AssetOptions
---@field kind string|nil
---@field virtual_path string|nil
---@field output_path string|nil
---@field metadata table|nil

---@class GeneratedAssetOptions
---@field kind string|nil
---@field output_path string|nil
---@field metadata table|nil

---Import a plugin. Prefer `ballad.plugins.*`; string literal overloads are provided
---for existing partituras such as `p:use("moonstone")`.
---@param plugin_ref string|PluginContract
---@return PluginProxy
---@overload fun(self: PipelineContext, plugin_ref: MoonstonePluginContract): MoonstonePlugin
---@overload fun(self: PipelineContext, plugin_ref: LayoutPluginContract): LayoutPlugin
---@overload fun(self: PipelineContext, plugin_ref: LovePluginContract): LovePlugin
---@overload fun(self: PipelineContext, plugin_ref: RegistryPluginContract): RegistryPlugin
---@overload fun(self: PipelineContext, plugin_ref: NvimPluginContract): NvimPlugin
---@overload fun(self: PipelineContext, plugin_ref: RuntimePluginContract): RuntimePlugin
---@overload fun(self: PipelineContext, plugin_ref: WatcherPluginContract): WatcherPlugin
---@overload fun(self: PipelineContext, plugin_ref: LuaPluginContract): LuaPlugin
---@overload fun(self: PipelineContext, plugin_ref: MoonstoneInputPluginContract): MoonstoneInputPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'moonstone'|'ballad.plugins.moonstone'): MoonstonePlugin
---@overload fun(self: PipelineContext, plugin_ref: 'layout'|'ballad.plugins.layout'): LayoutPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'love'|'ballad.plugins.love'): LovePlugin
---@overload fun(self: PipelineContext, plugin_ref: 'registry'|'ballad.plugins.registry'): RegistryPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'nvim'|'ballad.plugins.nvim'): NvimPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'runtime'|'ballad.plugins.runtime'): RuntimePlugin
---@overload fun(self: PipelineContext, plugin_ref: 'watcher'|'ballad.plugins.watcher'): WatcherPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'lua'|'ballad.plugins.lua'): LuaPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'input.moonstone'|'ballad.plugins.input.moonstone'): MoonstoneInputPlugin
if _G.PipelineContext then function PipelineContext:use(plugin_ref) end end

---@class PipelineSourceNamespace
---@field directory fun(path: string, opts: SourceDirectoryOptions|nil): AssetNode Introduce every file below a directory.
---@field files fun(patterns: string|string[], opts: SourceFilesOptions|nil): AssetNode Introduce files matching glob-style patterns.
---@field stdin fun(opts: SourceStdinOptions|nil): AssetNode Introduce stdin as a generated asset.

---@class SourceDirectoryOptions
---@field path string|nil Directory path; supplied by the first argument when omitted.
---@field root string|nil Alias for `path`.
---@field label string|nil Node label for diagnostics.
---@field metadata table|nil Metadata copied to created assets.
---@field enabled boolean|nil Set false to disable the source.
---@field progress_weight number|nil Progress weight for planning.

---@class SourceFilesOptions
---@field root string|nil Root to scan, defaults to `.`.
---@field patterns string|string[]|nil Glob-style patterns; supplied by first argument.
---@field label string|nil Node label for diagnostics.
---@field metadata table|nil Metadata copied to created assets.
---@field enabled boolean|nil Set false to disable the source.
---@field progress_weight number|nil Progress weight for planning.

---@class SourceStdinOptions
---@field name string|nil Virtual file name, defaults to `stdin`.
---@field kind string|nil Asset kind, defaults to `generated`.
---@field label string|nil Node label for diagnostics.
---@field metadata table|nil Metadata copied to created asset.
---@field enabled boolean|nil Set false to disable the source.
---@field progress_weight number|nil Progress weight for planning.

---@class PipelineSinkNamespace
---@field directory fun(input: NodeHandle, opts: SinkDirectoryOptions): NodeHandle Materialize assets into a directory.
---@field stdout fun(input: NodeHandle, opts: SinkStdoutOptions|nil): NodeHandle Print asset/file graph data to stdout.
---@field file_graph fun(input: NodeHandle, opts: SinkFileGraphOptions): NodeHandle Write a `file-graph.json`-style JSON file.
---@field artifact fun(input: NodeHandle, opts: SinkArtifactOptions): NodeHandle Materialize a single artifact path or directory.
---@field none fun(input?: NodeHandle|AssetSet|nil, opts?: table|nil): NodeHandle Ignore or suppress output for an input asset set.

---@class SinkDirectoryOptions
---@field out string Output directory.
---@field path string|nil Alias for `out`.
---@field file_graph boolean|nil Also write `file-graph.json` inside the output directory.
---@field label string|nil Node label for diagnostics.
---@field enabled boolean|nil Set false to disable the sink.
---@field progress_weight number|nil Progress weight for planning.

---@class SinkStdoutOptions
---@field file_graph boolean|nil Print full file graph instead of the flat asset list.
---@field label string|nil Node label for diagnostics.
---@field enabled boolean|nil Set false to disable the sink.
---@field progress_weight number|nil Progress weight for planning.

---@class SinkFileGraphOptions
---@field out string Output JSON path.
---@field path string|nil Alias for `out`.
---@field label string|nil Node label for diagnostics.
---@field enabled boolean|nil Set false to disable the sink.
---@field progress_weight number|nil Progress weight for planning.

---@class SinkArtifactOptions
---@field out string Output file or directory path.
---@field label string|nil Node label for diagnostics.
---@field enabled boolean|nil Set false to disable the sink.
---@field progress_weight number|nil Progress weight for planning.

---@class PluginCtx
---@field graph Graph
---@field node table
---@field warn fun(message: string)
---@field fail fun(message: string)
---@field metadata fun(key: string, value: any)
---@field native_task fun(self: PluginCtx, opts: NativeTaskOptions): AssetSet

---@class PluginProxy: table
---@field _name? string
---@field _graph? Graph
---@field _host? table
---@field _ctx? PipelineContext
---@field [string] fun(input_or_opts: NodeHandle|table|nil, opts: table|nil): NodeHandle

---@class MoonstoneProjectOptions
---@field root string|nil Project root, defaults to `.`.
---@field roles BalladDependencyRole[]|nil Lockfile roles to include; defaults to `{ "runtime" }`.
---@field moon string|nil Moonstone executable for local store queries; defaults to `moon`.
---@field moon_bin string|nil Alias for `moon`.

---@class MoonstonePlugin: PluginProxy
---@field project fun(opts: MoonstoneProjectOptions|nil): MoonstoneProject Read `moonstone.toml`, lockfile, and `.moonstone/env` metadata.

---@class MoonstoneInputOptions
---@field root string|nil Project root, defaults to `.`.
---@field roles BalladDependencyRole[]|nil Lockfile roles to include; defaults to `{ "runtime" }`.
---@field moon string|nil Moonstone executable for local store queries; defaults to `moon`.
---@field moon_bin string|nil Alias for `moon`.

---@class MoonstonePackagesNode: AssetNode
---@field root string Project root.
---@field packages MoonstoneResolvedPackage[] Enriched packages selected from `moonstone.lock`.

---@class MoonstoneInputPlugin: PluginProxy
---@field packages fun(opts: MoonstoneInputOptions|nil): MoonstonePackagesNode Read `moonstone.lock` and enrich selected packages via `moon store query`.
---@field enrich_packages fun(packages: table[]|nil, opts: MoonstoneInputOptions|nil): MoonstoneResolvedPackage[] Enrich lockfile package records via `moon store query`.

---@class LayoutLibexecOptions
---@field name string|nil App directory name under `libexec/`, defaults to `app`.
---@field entry string|nil Entry script inside the app tree, defaults to `src/main.lua`.
---@field bin string|nil Launcher name under `bin/`, defaults to `name` or `app`.
---@field interpreter string|nil Interpreter used by launcher, defaults to `lua`.
---@field runnable boolean|nil Whether to generate the layout launcher, defaults to true.
---@field bundle_runtime boolean|nil Bundle runtime binary (`lua`/`luajit`) into `bin/`.
---@field bundle_interpreter boolean|nil Alias for `bundle_runtime`.
---@field include string[]|nil Project file glob patterns to export; defaults to all non-generated project files.
---@field exclude string[]|nil Project file glob patterns to omit after inclusion.
---@field lua_paths string[]|nil Relative Lua module roots in the launcher; defaults to `{ "lua", "src" }`.
---@field packages string[]|nil Package names whose projected Lua/C modules are included; defaults to all runtime-projected modules.
---@field depends_on NodeHandle|NodeHandle[]|nil Nodes that must finish before the layout reads generated project files.

---@class LayoutExecOptions: LayoutLibexecOptions

---@class LayoutFlatOptions
---@field name string|nil Package/app name.
---@field entry string|nil Entry script, defaults to `src/main.lua`.
---@field kind string|nil Package kind, e.g. `script`, `bin`, or `lib`.
---@field bin string|nil Launcher name when runnable.
---@field interpreter string|nil Interpreter used by launcher, defaults to `lua`.
---@field runnable boolean|nil Whether to generate a launcher.
---@field bundle_runtime boolean|nil Bundle runtime binary (`lua`/`luajit`) into `bin/`.
---@field bundle_interpreter boolean|nil Alias for `bundle_runtime`.

---@class LayoutLoveOptions: LoveLayoutOptions

---@class LayoutPlugin: PluginProxy
---@field libexec fun(project: MoonstoneProject, opts: LayoutLibexecOptions): LayoutNode Build `libexec/<name>/` plus `bin/<bin>` launcher assets.
---@field exec fun(project: MoonstoneProject, opts: LayoutExecOptions): LayoutNode Build a ready-to-run executable app layout backed by `libexec/<name>/`.
---@field flat fun(project: MoonstoneProject, opts: LayoutFlatOptions|nil): LayoutNode Build a root-relative Lua layout.
---@field love fun(project: MoonstoneProject, opts: LayoutLoveOptions|nil): LayoutNode LÖVE layout hook; prefer `ballad.plugins.love.layout`.

---@class LoveLayoutOptions
---@field main string|nil Path to `main.lua`, defaults to `main.lua`.
---@field conf string|nil Optional `conf.lua` path.
---@field include string[]|nil Glob patterns to include; defaults to all non-excluded files.
---@field exclude string[]|nil Glob patterns to exclude; defaults to `.moonstone/**`, `.ballad/**`, `dist/**`, `.git/**`.
---@field runtime string|nil Runtime dependency metadata, defaults to `love@11.5`.
---@field lua_api string|nil Lua API metadata, defaults to `love-11`.
---@field lua_abi BalladLuaAbi|nil Lua ABI metadata, defaults to `5.1`.

---@class LovePackOptions
---@field out string|nil Output `.love` path, defaults to `dist/<project>.love`.
---@field tool string|nil Zip tool for non-deterministic mode, defaults to `zip`.
---@field deterministic boolean|nil Use deterministic built-in zip writer, defaults to true.

---@class LovePlugin: PluginProxy
---@field layout fun(project: MoonstoneProject, opts: LoveLayoutOptions): LayoutNode Build a LÖVE-compatible asset layout.
---@field pack fun(layout: LayoutNode, opts: LovePackOptions|nil): ArtifactNode Pack a LÖVE layout into a `.love` archive asset.

---@class RegistryPackageOptions
---@field name string Package name to put in `package.toml`, e.g. `moonstone/ballad`.
---@field version string Package version.
---@field target string|nil Artifact target, defaults to `any`.
---@field runtime string|nil Runtime requirement, e.g. `moonstone/luajit@2.1.0`.
---@field lua_abi BalladLuaAbi|nil Lua ABI metadata, defaults to `5.1`.
---@field lua_api string|nil Lua API metadata.
---@field kind string|nil Package kind, defaults to layout metadata or `bin`.
---@field artifact_kind string|nil Artifact kind, defaults to layout metadata or `bin`.
---@field description string|nil Package description.
---@field readme string|nil Path to README file (defaults to README.md if present).
---@field readme_content string|nil Direct string content for README.md.
---@field artifact_url string|nil External HTTPS URL used by `publish.sh` when `MOONSTONE_ARTIFACT_URL` is set; keeps release archives outside the registry blob store.

---@class RegistryRuntimeOptions
---@field name string|nil Runtime name, defaults to env `RUNTIME_NAME` or `lua`.
---@field version string Runtime version; required unless `RUNTIME_VERSION` is set.
---@field artifacts_dir string|nil Directory containing runtime artifacts.
---@field out string|nil Output directory for descriptor and publish script.
---@field registry_url string|nil Publish endpoint URL.
---@field token string|nil Publish token.
---@field publish boolean|string|nil Publish immediately when true.
---@field lua_abi BalladLuaAbi|nil Runtime Lua ABI.
---@field lua_api string|nil Runtime Lua API.
---@field description string|nil Runtime package description.
---@field bins table<string,string>|nil Provided binaries, mapping name to path.

---@class RegistryPlugin: PluginProxy
---@field package fun(layout: LayoutNode, opts: RegistryPackageOptions): RegistryArtifactNode Build registry `package.toml`, tarball, and publish script from a layout.
---@field runtime fun(opts: RegistryRuntimeOptions): RegistryArtifactNode Build registry descriptor/publish script for prebuilt runtime artifacts.

---@class NvimDependencySpec
---@field role BalladDependencyRole Dependency role.
---@field package string|nil Registry package reference, e.g. `nvim-lua/plenary.nvim`.
---@field constraint string|nil Version constraint, e.g. `*` or `^1.0`.
---@field optional boolean|nil Marks optional dependency.

---@class NvimLayoutOptions
---@field module string|nil Top-level Lua module name, e.g. `my_plugin`.
---@field include string[]|nil Glob patterns for files to include.
---@field exclude string[]|nil Glob patterns for files to exclude.
---@field runtime string|nil Runtime requirement metadata, e.g. `nvim@0.10`.
---@field lua_api string|nil API metadata, e.g. `nvim-0.10`.
---@field lua_abi BalladLuaAbi|nil Lua ABI metadata.
---@field dependencies table<string,NvimDependencySpec>|nil Declared plugin dependencies.
---@field unresolved 'warn'|'fail'|nil Behavior for unknown `require` calls, defaults to `warn`.

---@class NvimHelptagsOptions
---@field doc string|nil Directory containing help files, defaults to `doc`.

---@class NvimDiscoverOptions
---@field unresolved 'warn'|'fail'|nil Behavior for unknown `require` calls.

---@class NvimPlugin: PluginProxy
---@field layout fun(project: MoonstoneProject, opts: NvimLayoutOptions|nil): LayoutNode Build a Neovim runtimepath-compatible layout.
---@field helptags fun(layout: LayoutNode, opts: NvimHelptagsOptions|nil): LayoutNode Generate or declare helptags for `doc/*.txt`.
---@field discover fun(layout: LayoutNode, opts: NvimDiscoverOptions|nil): LayoutNode Scan modules/requires and attach dependency metadata.

---@class RuntimeWrapOptions
---@field mode 'ship'|'global'|'fallback'|'none'|nil Runtime strategy, defaults to `ship`.
---@field source MoonstoneRuntime|nil Runtime metadata, defaults to `project.runtime` from `moonstone.project`.
---@field command string|nil Global runtime command for `global`/`fallback`, defaults to runtime name or `lua`.
---@field shim boolean|nil Whether to generate launcher scripts, defaults to true.
---@field entry string|nil Entry path inside the output layout; defaults from layout metadata.
---@field launcher string|nil Unix launcher path, defaults to `run`.
---@field bin string|nil Alias for `launcher`.
---@field runtime_bin string|nil Runtime binary relative to artifact root, defaults to `source.bin.lua` or `source.bin.luajit`.
---@field lua_roots string[]|nil Lua module roots inside output layout.
---@field cpath_roots string[]|nil Native module roots inside output layout.
---@field windows boolean|nil Set false to skip `.bat` launcher generation.
---@field enabled boolean|nil Legacy: false maps to `mode = "none"`.
---@field include_runtime boolean|nil Legacy: false maps to `mode = "global"`.

---@class RuntimePlugin: PluginProxy
---@field wrap fun(input: NodeHandle, opts: RuntimeWrapOptions|nil): LayoutNode Add runtime assets, launcher scripts, and runtime metadata to a layout.
---@field bundle fun(input: NodeHandle, opts: RuntimeWrapOptions|nil): LayoutNode Compatibility alias for `wrap`.
---@class WatcherPlugin: PluginProxy
---@field watch fun(spec: WatcherSpec): WatcherSessionNode Run an ordered watcher session with one optional bootstrap and change-only reactions.

---@class WatcherReaction
---@field label string|nil Human-readable reaction label used in logs.
---@field watch NodeHandle[] Non-empty source node handles that determine when this reaction fires.
---@field outputs string[]|nil Paths refreshed by the effect; retained in session metadata and graph debug output.
---@field effect string Shell command run with `BALLAD_WATCH_REASON=change` after a matching debounced change.

---@class WatcherInitialAction
---@field label string|nil Human-readable bootstrap label used in logs.
---@field effect string Shell command run once with `BALLAD_WATCH_REASON=initial` before snapshots begin.
---@field outputs string[]|nil Paths refreshed by the bootstrap; retained in session metadata and graph debug output.

---@class WatcherOptions
---@field cwd string|nil Working directory for bootstrap, reactions, and cleanup commands.
---@field cleanup string|nil Shell command invoked exactly once by the POSIX supervisor on normal exit or `INT`, `TERM`, or `HUP`.
---@field interval number|nil Poll interval in seconds; defaults to `0.5`.
---@field debounce number|nil Quiet period before a changed reaction runs; defaults to `0.1`.
---@field state_dir string|nil Directory for the generated supervised shell script; defaults to `.ballad/watchers`.
---@field once boolean|nil Run only `initial` and return without starting a daemon; useful for CI and smoke tests.

---@class WatcherSpec
---@field initial WatcherInitialAction|nil Optional bootstrap action that runs exactly once before change detection.
---@field reactions WatcherReaction[] Ordered non-empty change-only reaction list.
---@field options WatcherOptions|nil Supervisor configuration.

---@class WatcherSessionNode: NodeHandle

---@class LuaCompileOptions
---@field enabled boolean|nil Reserved.
---@class LuaCheckOptions
---@field enabled boolean|nil Reserved.

---@class LuaPlugin: PluginProxy
---@field compile fun(input: NodeHandle, opts: LuaCompileOptions|nil): AssetNode Reserved compile transform; currently fails until implemented.
---@field check fun(input: NodeHandle, opts: LuaCheckOptions|nil): AssetNode Reserved static-check transform; currently fails until implemented.

---@class Graph
---@field nodes table<string, table>
---@field assets table<string, Asset>
---@field native_tasks table[]

---@type Ballad
local ballad
return ballad
