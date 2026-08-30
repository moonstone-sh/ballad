const std = @import("std");

pub const StringMap = std.json.ArrayHashMap([]const u8);

pub const Action = struct {
    id: ?[]const u8 = null,
    argv: []const []const u8,
    cwd: []const u8,
    env: StringMap,
    inputs: []const []const u8,
    outputs: []const []const u8,
    cacheable: bool,
    toolchain_fingerprint: ?[]const u8 = null,
};

pub const Step = struct {
    label: []const u8,
    outputs: []const []const u8,
    action: ?Action = null,
};

pub const Reaction = struct {
    label: []const u8,
    source_nodes: []const []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    action: ?Action = null,
};

pub const Document = struct {
    contract: []const u8,
    node: []const u8,
    mode: []const u8,
    cwd: []const u8,
    interval: f64,
    debounce: f64,
    initial: ?Step = null,
    reactions: []const Reaction,
    output_exclusions: []const []const u8,
};

pub const Error = error{
    InvalidContract,
    InvalidMode,
    InvalidString,
    InvalidInterval,
    InvalidDebounce,
    MissingReactions,
    MissingInputs,
    MissingAction,
    EmptyArgv,
    CommandShellAction,
    InvalidEnvironment,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Document) {
    var parsed = try std.json.parseFromSlice(Document, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    try validate(&parsed.value);
    return parsed;
}

pub fn validate(document: *const Document) Error!void {
    if (!std.mem.eql(u8, document.contract, "ballad:watcher:v1")) return error.InvalidContract;
    if (!std.mem.eql(u8, document.mode, "once") and !std.mem.eql(u8, document.mode, "daemon")) return error.InvalidMode;
    try requireString(document.node);
    try requireString(document.cwd);
    if (!std.math.isFinite(document.interval) or document.interval <= 0) return error.InvalidInterval;
    if (!std.math.isFinite(document.debounce) or document.debounce < 0) return error.InvalidDebounce;
    if (document.reactions.len == 0) return error.MissingReactions;
    for (document.output_exclusions) |output| try requirePath(output);
    if (document.initial) |initial| try validateStep(initial);
    for (document.reactions) |reaction| {
        try requireString(reaction.label);
        if (reaction.source_nodes.len == 0 or reaction.inputs.len == 0) return error.MissingInputs;
        for (reaction.source_nodes) |node| try requireString(node);
        for (reaction.inputs) |input| try requirePath(input);
        for (reaction.outputs) |output| try requirePath(output);
        const action = reaction.action orelse return error.MissingAction;
        try validateAction(action);
    }
}

fn validateStep(step: Step) Error!void {
    try requireString(step.label);
    for (step.outputs) |output| try requirePath(output);
    const action = step.action orelse return error.MissingAction;
    try validateAction(action);
}

fn validateAction(action: Action) Error!void {
    if (action.id) |id| try requireString(id);
    if (action.argv.len == 0) return error.EmptyArgv;
    for (action.argv, 0..) |argument, index| {
        try requireString(argument);
        if (index == 0 and isCmdScript(argument)) return error.CommandShellAction;
    }
    try requireString(action.cwd);
    for (action.inputs) |input| try requirePath(input);
    for (action.outputs) |output| try requirePath(output);
    if (action.toolchain_fingerprint) |fingerprint| try requireString(fingerprint);
    var it = action.env.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (key.len == 0 or std.mem.indexOfScalar(u8, key, '=') != null) return error.InvalidEnvironment;
        try requireString(key);
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironment;
    }
}

fn requirePath(value: []const u8) Error!void {
    try requireString(value);
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-' or byte == '/' or byte == '\\' or byte == '*' or byte == '?')) return error.InvalidString;
    }
}

fn requireString(value: []const u8) Error!void {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidString;
}

fn isCmdScript(path: []const u8) bool {
    if (path.len < 4) return false;
    const suffix = path[path.len - 4 ..];
    return std.ascii.eqlIgnoreCase(suffix, ".cmd") or std.ascii.eqlIgnoreCase(suffix, ".bat");
}

test "v1 manifest accepts direct argv and rejects shell scripts" {
    const good =
        \\{"contract":"ballad:watcher:v1","node":"node_1","mode":"once","cwd":".","interval":0.5,"debounce":0,"initial":{"label":"initial","outputs":[],"action":{"argv":["tool.exe","argument with spaces"],"cwd":".","env":{},"inputs":[],"outputs":[],"cacheable":true}},"reactions":[{"label":"sources","source_nodes":["node_0"],"inputs":["src/**/*.lua"],"outputs":[],"action":{"argv":["tool.exe"],"cwd":".","env":{},"inputs":[],"outputs":[],"cacheable":true}}],"output_exclusions":[]}
    ;
    var parsed = try parse(std.testing.allocator, good);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("once", parsed.value.mode);

    const bad =
        \\{"contract":"ballad:watcher:v1","node":"node_1","mode":"once","cwd":".","interval":1,"debounce":0,"reactions":[{"label":"sources","source_nodes":["node_0"],"inputs":["src/**"],"outputs":[],"action":{"argv":["build.cmd"],"cwd":".","env":{},"inputs":[],"outputs":[],"cacheable":true}}],"output_exclusions":[]}
    ;
    try std.testing.expectError(error.CommandShellAction, parse(std.testing.allocator, bad));
}
