const std = @import("std");
const manifest = @import("manifest.zig");
const w = std.os.windows;

const HANDLE = w.HANDLE;
const BOOL = w.BOOL;
const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;

const FILE_LIST_DIRECTORY: u32 = 0x0001;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const FILE_SHARE_DELETE: u32 = 0x00000004;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const FILE_NOTIFY_CHANGE_FILE_NAME: u32 = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME: u32 = 0x00000002;
const FILE_NOTIFY_CHANGE_SIZE: u32 = 0x00000008;
const FILE_NOTIFY_CHANGE_LAST_WRITE: u32 = 0x00000010;
const FILE_NOTIFY_CHANGE_CREATION: u32 = 0x00000040;
const ERROR_IO_PENDING: u32 = 997;
const ERROR_OPERATION_ABORTED: u32 = 995;
const ERROR_NO_MORE_FILES: u32 = 18;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;
const WAIT_FAILED: u32 = 0xffffffff;
const INFINITE: u32 = 0xffffffff;
const MAXIMUM_WAIT_OBJECTS: usize = 64;
const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: u32 = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x00002000;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    offset: extern union { pair: extern struct { Offset: u32, OffsetHigh: u32 }, Pointer: ?*anyopaque } = .{ .pair = .{ .Offset = 0, .OffsetHigh = 0 } },
    hEvent: ?HANDLE = null,
};

const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: u32,
    Action: u32,
    FileNameLength: u32,
    FileName: [1]u16,
};

const FILETIME = extern struct { low: u32, high: u32 };
const WIN32_FIND_DATAW = extern struct {
    attributes: u32,
    creation: FILETIME,
    access: FILETIME,
    write: FILETIME,
    size_high: u32,
    size_low: u32,
    reserved0: u32,
    reserved1: u32,
    name: [260]u16,
    alternate_name: [14]u16,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    per_process_user_time_limit: i64 = 0,
    per_job_user_time_limit: i64 = 0,
    limit_flags: u32 = 0,
    minimum_working_set_size: usize = 0,
    maximum_working_set_size: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};
const IO_COUNTERS = extern struct { read_operation_count: u64 = 0, write_operation_count: u64 = 0, other_operation_count: u64 = 0, read_transfer_count: u64 = 0, write_transfer_count: u64 = 0, other_transfer_count: u64 = 0 };
const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    basic: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    io: IO_COUNTERS = .{},
    process_memory_limit: usize = 0,
    job_memory_limit: usize = 0,
    peak_process_memory_used: usize = 0,
    peak_job_memory_used: usize = 0,
};

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) BOOL, BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn ReadDirectoryChangesW(HANDLE, ?*anyopaque, u32, BOOL, u32, ?*u32, *OVERLAPPED, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(HANDLE, *OVERLAPPED, *u32, BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(HANDLE, ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const HANDLE, BOOL, u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(HANDLE, u32, *const anyopaque, u32) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(HANDLE, HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(HANDLE, u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(HANDLE, *u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]u16;
extern "kernel32" fn FreeEnvironmentStringsW([*:0]u16) callconv(.winapi) BOOL;
extern "kernel32" fn FindFirstFileW([*:0]const u16, *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextFileW(HANDLE, *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) BOOL;

var shutdown_event: ?HANDLE = null;

fn ctrlHandler(_: u32) callconv(.winapi) BOOL {
    if (shutdown_event) |event| _ = SetEvent(event);
    return .TRUE;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--manifest")) return error.InvalidArguments;
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(16 * 1024 * 1024));
    const parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    var session = try Session.init(allocator, &parsed.value);
    defer session.deinit();
    try session.run();
    try writeResult(parsed.value.mode);
}

fn writeResult(mode: []const u8) !void {
    const stdout = GetStdHandle(0xfffffff5) orelse return error.NoStdout;
    const status = if (std.mem.eql(u8, mode, "once")) "completed" else "stopped";
    var buffer: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"contract\":\"ballad:watcher-result:v1\",\"status\":\"{s}\",\"mode\":\"{s}\"}}\n", .{ status, mode });
    var written: u32 = 0;
    if (!WriteFile(stdout, line.ptr, @intCast(line.len), &written, null).toBool() or written != line.len) return error.StdoutWriteFailed;
}

const WatchRoot = struct {
    logical: []const u8,
    absolute: []const u8,
    handle: HANDLE,
    event: HANDLE,
    overlapped: OVERLAPPED,
    buffer: [64 * 1024]u8 align(@alignOf(FILE_NOTIFY_INFORMATION)),

    fn deinit(self: *WatchRoot) void {
        _ = CancelIoEx(self.handle, &self.overlapped);
        w.CloseHandle(self.event);
        w.CloseHandle(self.handle);
    }

    fn arm(self: *WatchRoot) !void {
        self.overlapped = .{ .hEvent = self.event };
        const filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION;
        if (!ReadDirectoryChangesW(self.handle, &self.buffer, self.buffer.len, .TRUE, filter, null, &self.overlapped, null).toBool()) {
            if (@intFromEnum(w.GetLastError()) != ERROR_IO_PENDING) return error.ReadDirectoryChangesFailed;
        }
    }
};

const Pending = struct { generation: u64 = 0, deadline: u64 = 0, complete: u64 = 0 };

const SnapshotEntry = struct { path: []u8, write_time: u64, size: u64 };
const Snapshot = struct {
    entries: std.ArrayList(SnapshotEntry) = .empty,
    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.path);
        self.entries.deinit(allocator);
    }
};

const Session = struct {
    allocator: std.mem.Allocator,
    document: *const manifest.Document,
    shutdown: HANDLE,
    job: HANDLE,
    roots: std.ArrayList(WatchRoot) = .empty,
    pending: []Pending,
    generation: u64 = 0,
    snapshot: Snapshot = .{},

    fn init(allocator: std.mem.Allocator, document: *const manifest.Document) !Session {
        const shutdown = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.CreateShutdownEventFailed;
        errdefer w.CloseHandle(shutdown);
        shutdown_event = shutdown;
        if (!SetConsoleCtrlHandler(ctrlHandler, .TRUE).toBool()) return error.ConsoleHandlerFailed;
        errdefer _ = SetConsoleCtrlHandler(ctrlHandler, .FALSE);

        const job = CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
        errdefer w.CloseHandle(job);
        var limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        limits.basic.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, &limits, @sizeOf(@TypeOf(limits))).toBool()) return error.ConfigureJobFailed;

        const pending = try allocator.alloc(Pending, document.reactions.len);
        @memset(pending, .{});
        return .{ .allocator = allocator, .document = document, .shutdown = shutdown, .job = job, .pending = pending };
    }

    fn deinit(self: *Session) void {
        _ = SetConsoleCtrlHandler(ctrlHandler, .FALSE);
        shutdown_event = null;
        for (self.roots.items) |*root| root.deinit();
        self.roots.deinit(self.allocator);
        self.snapshot.deinit(self.allocator);
        self.allocator.free(self.pending);
        w.CloseHandle(self.job);
        w.CloseHandle(self.shutdown);
    }

    fn run(self: *Session) !void {
        if (self.document.initial) |initial| try self.runAction(initial.action.?, "initial");
        if (std.mem.eql(u8, self.document.mode, "once")) return;

        try self.openRoots();
        self.snapshot = try self.captureSnapshot();
        for (self.roots.items) |*root| try root.arm();
        try self.daemon();
    }

    fn openRoots(self: *Session) !void {
        for (self.document.reactions) |reaction| for (reaction.inputs) |input| {
            const logical = try watchRoot(self.allocator, input);
            defer self.allocator.free(logical);
            if (self.hasRoot(logical)) continue;
            if (self.roots.items.len + 1 >= MAXIMUM_WAIT_OBJECTS) return error.TooManyWatchRoots;
            const absolute = try std.fs.path.join(self.allocator, &.{ self.document.cwd, logical });
            const absolute_z = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, absolute);
            defer self.allocator.free(absolute_z);
            const handle = CreateFileW(absolute_z, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
            if (handle == INVALID_HANDLE_VALUE) return error.WatchRootUnavailable;
            errdefer w.CloseHandle(handle);
            const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.CreateWatchEventFailed;
            errdefer w.CloseHandle(event);
            try self.roots.append(self.allocator, .{ .logical = try self.allocator.dupe(u8, logical), .absolute = absolute, .handle = handle, .event = event, .overlapped = .{}, .buffer = undefined });
        };
    }

    fn hasRoot(self: *const Session, logical: []const u8) bool {
        for (self.roots.items) |root| if (equalPath(root.logical, logical)) return true;
        return false;
    }

    fn daemon(self: *Session) !void {
        while (true) {
            var handles: [MAXIMUM_WAIT_OBJECTS]HANDLE = undefined;
            handles[0] = self.shutdown;
            for (self.roots.items, 0..) |root, index| handles[index + 1] = root.event;
            const wait = WaitForMultipleObjects(@intCast(self.roots.items.len + 1), &handles, .FALSE, self.nextTimeout());
            if (wait == WAIT_FAILED) return error.WaitFailed;
            if (wait == WAIT_OBJECT_0) return;
            if (wait == WAIT_TIMEOUT) {
                try self.runDue();
                continue;
            }
            const root_index: usize = wait - WAIT_OBJECT_0 - 1;
            if (root_index >= self.roots.items.len) return error.WaitFailed;
            try self.consumeRoot(root_index);
            try self.runDue();
        }
    }

    fn nextTimeout(self: *const Session) u32 {
        const now = GetTickCount64();
        var nearest: ?u64 = null;
        for (self.pending) |pending| {
            if (pending.generation > pending.complete) nearest = if (nearest) |value| @min(value, pending.deadline) else pending.deadline;
        }
        if (nearest == null) return INFINITE;
        if (nearest.? <= now) return 0;
        return @intCast(@min(nearest.? - now, @as(u64, 0xfffffffe)));
    }

    fn consumeRoot(self: *Session, root_index: usize) !void {
        var bytes: u32 = 0;
        const root = &self.roots.items[root_index];
        if (!GetOverlappedResult(root.handle, &root.overlapped, &bytes, .FALSE).toBool()) {
            const code = @intFromEnum(w.GetLastError());
            if (code == ERROR_OPERATION_ABORTED and isStopping(self.shutdown)) return;
            return error.GetOverlappedResultFailed;
        }
        if (bytes == 0) {
            try self.rescanAfterOverflow();
        } else {
            try self.consumeEvents(root, bytes);
            const updated = try self.captureSnapshot();
            self.snapshot.deinit(self.allocator);
            self.snapshot = updated;
        }
        if (!isStopping(self.shutdown)) try root.arm();
    }

    fn consumeEvents(self: *Session, root: *const WatchRoot, bytes: u32) !void {
        var offset: usize = 0;
        while (offset < bytes) {
            const info: *const FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(root.buffer[offset..].ptr));
            const name_len: usize = info.FileNameLength / 2;
            const name = try std.unicode.utf16LeToUtf8Alloc(self.allocator, info.FileName[0..name_len]);
            defer self.allocator.free(name);
            const relative = try joinLogical(self.allocator, root.logical, name);
            defer self.allocator.free(relative);
            try self.markPath(relative);
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }

    fn rescanAfterOverflow(self: *Session) !void {
        var updated = try self.captureSnapshot();
        defer updated.deinit(self.allocator);
        var old_index: usize = 0;
        var new_index: usize = 0;
        while (old_index < self.snapshot.entries.items.len or new_index < updated.entries.items.len) {
            const changed = blk: {
                if (old_index == self.snapshot.entries.items.len) {
                    const path = updated.entries.items[new_index].path; new_index += 1; break :blk path;
                }
                if (new_index == updated.entries.items.len) {
                    const path = self.snapshot.entries.items[old_index].path; old_index += 1; break :blk path;
                }
                const old = self.snapshot.entries.items[old_index];
                const new = updated.entries.items[new_index];
                switch (std.mem.order(u8, old.path, new.path)) {
                    .lt => { old_index += 1; break :blk old.path; },
                    .gt => { new_index += 1; break :blk new.path; },
                    .eq => { old_index += 1; new_index += 1; if (old.write_time == new.write_time and old.size == new.size) continue; break :blk new.path; },
                }
            };
            try self.markPath(changed);
        }
        self.snapshot.deinit(self.allocator);
        self.snapshot = updated;
        updated = .{};
    }

    fn markPath(self: *Session, relative: []const u8) !void {
        if (self.isExcluded(relative)) return;
        var matched = false;
        for (self.document.reactions, 0..) |reaction, index| {
            for (reaction.inputs) |input| if (globMatch(input, relative)) {
                matched = true;
                break;
            };
            if (matched) self.queue(index);
            matched = false;
        }
    }

    fn queue(self: *Session, index: usize) void {
        self.generation +%= 1;
        const delay: u64 = @intFromFloat(self.document.debounce * 1000.0);
        self.pending[index].generation = self.generation;
        self.pending[index].deadline = GetTickCount64() + delay;
    }

    fn isExcluded(self: *const Session, relative: []const u8) bool {
        for (self.document.output_exclusions) |output| if (pathContains(output, relative)) return true;
        return false;
    }

    fn runDue(self: *Session) !void {
        const now = GetTickCount64();
        for (self.document.reactions, 0..) |reaction, index| {
            const pending = &self.pending[index];
            if (pending.generation <= pending.complete or pending.deadline > now) continue;
            const generation = pending.generation;
            try self.runAction(reaction.action.?, "change");
            pending.complete = generation;
            if (isStopping(self.shutdown)) return;
        }
    }

    fn runAction(self: *Session, action: manifest.Action, reason: []const u8) !void {
        if (isStopping(self.shutdown)) return error.Cancelled;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const cwd = try std.fs.path.join(allocator, &.{ self.document.cwd, action.cwd });
        const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd);
        const command = try commandLine(allocator, action.argv);
        const environment = try environmentBlock(allocator, action.env, reason);
        var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
        startup.cb = @sizeOf(w.STARTUPINFOW);
        var process: w.PROCESS.INFORMATION = undefined;
        if (!w.kernel32.CreateProcessW(null, command.ptr, null, null, .FALSE, @bitCast(CREATE_UNICODE_ENVIRONMENT), environment.ptr, cwd_w.ptr, &startup, &process).toBool()) return error.CreateProcessFailed;
        defer w.CloseHandle(process.hThread);
        defer w.CloseHandle(process.hProcess);
        if (!AssignProcessToJobObject(self.job, process.hProcess).toBool()) {
            _ = TerminateJobObject(self.job, 1);
            return error.AssignJobFailed;
        }
        const handles = [_]HANDLE{ self.shutdown, process.hProcess };
        const wait = WaitForMultipleObjects(2, &handles, .FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0) {
            if (!TerminateJobObject(self.job, 1).toBool()) return error.TerminateJobFailed;
            const child_only = [_]HANDLE{process.hProcess};
            if (WaitForMultipleObjects(1, &child_only, .FALSE, 5000) != WAIT_OBJECT_0) return error.ChildCleanupTimedOut;
            return error.Cancelled;
        }
        if (wait != WAIT_OBJECT_0 + 1) return error.WaitFailed;
        var code: u32 = 1;
        if (!GetExitCodeProcess(process.hProcess, &code).toBool()) return error.ExitCodeFailed;
        if (code != 0) return error.ActionFailed;
    }

    fn captureSnapshot(self: *Session) !Snapshot {
        var snapshot: Snapshot = .{};
        errdefer snapshot.deinit(self.allocator);
        for (self.roots.items) |root| try scanDirectory(self.allocator, &snapshot, root.absolute, root.logical);
        std.mem.sort(SnapshotEntry, snapshot.entries.items, {}, struct {
            fn less(_: void, a: SnapshotEntry, b: SnapshotEntry) bool { return std.mem.order(u8, a.path, b.path) == .lt; }
        }.less);
        return snapshot;
    }
};

fn isStopping(event: HANDLE) bool {
    const handles = [_]HANDLE{event};
    return WaitForMultipleObjects(1, &handles, .FALSE, 0) == WAIT_OBJECT_0;
}

fn scanDirectory(allocator: std.mem.Allocator, snapshot: *Snapshot, absolute: []const u8, logical: []const u8) !void {
    const search = try std.fs.path.join(allocator, &.{ absolute, "*" });
    defer allocator.free(search);
    const search_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, search);
    defer allocator.free(search_w);
    var data: WIN32_FIND_DATAW = undefined;
    const handle = FindFirstFileW(search_w, &data);
    if (handle == INVALID_HANDLE_VALUE) return error.SnapshotScanFailed;
    defer _ = FindClose(handle);
    while (true) {
        const length = std.mem.indexOfScalar(u16, &data.name, 0) orelse data.name.len;
        const name = try std.unicode.utf16LeToUtf8Alloc(allocator, data.name[0..length]);
        defer allocator.free(name);
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            const child_logical = try joinLogical(allocator, logical, name);
            const child_absolute = try std.fs.path.join(allocator, &.{ absolute, name });
            defer allocator.free(child_absolute);
            const is_directory = data.attributes & FILE_ATTRIBUTE_DIRECTORY != 0;
            try snapshot.entries.append(allocator, .{ .path = child_logical, .write_time = (@as(u64, data.write.high) << 32) | data.write.low, .size = (@as(u64, data.size_high) << 32) | data.size_low });
            if (is_directory and data.attributes & FILE_ATTRIBUTE_REPARSE_POINT == 0) try scanDirectory(allocator, snapshot, child_absolute, child_logical);
        }
        if (!FindNextFileW(handle, &data).toBool()) {
            if (@intFromEnum(w.GetLastError()) == ERROR_NO_MORE_FILES) break;
            return error.SnapshotScanFailed;
        }
    }
}

fn commandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (argv, 0..) |argument, index| {
        if (index != 0) try bytes.append(allocator, ' ');
        try appendQuoted(&bytes, allocator, argument);
    }
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, bytes.items);
}

fn appendQuoted(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, argument: []const u8) !void {
    const quote = argument.len == 0 or std.mem.indexOfAny(u8, argument, " \t\"") != null;
    if (!quote) return bytes.appendSlice(allocator, argument);
    try bytes.append(allocator, '"');
    var slashes: usize = 0;
    for (argument) |byte| {
        if (byte == '\\') { slashes += 1; continue; }
        if (byte == '"') {
            try bytes.appendNTimes(allocator, '\\', slashes * 2 + 1);
            try bytes.append(allocator, '"');
        } else {
            try bytes.appendNTimes(allocator, '\\', slashes);
            try bytes.append(allocator, byte);
        }
        slashes = 0;
    }
    try bytes.appendNTimes(allocator, '\\', slashes * 2);
    try bytes.append(allocator, '"');
}

fn environmentBlock(allocator: std.mem.Allocator, extra: manifest.StringMap, reason: []const u8) ![:0]u16 {
    var entries: std.ArrayList([]const u8) = .empty;
    const source = GetEnvironmentStringsW() orelse return error.EnvironmentReadFailed;
    defer _ = FreeEnvironmentStringsW(source);
    var cursor: [*:0]u16 = source;
    while (cursor[0] != 0) {
        var length: usize = 0;
        while (cursor[length] != 0) : (length += 1) {}
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, cursor[0..length]);
        try entries.append(allocator, utf8);
        cursor += length + 1;
    }
    var it = extra.map.iterator();
    while (it.next()) |item| try overlayEnvironment(allocator, &entries, item.key_ptr.*, item.value_ptr.*);
    try overlayEnvironment(allocator, &entries, "BALLAD_WATCH_REASON", reason);
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool { return asciiLess(a, b); }
    }.less);
    var wide: std.ArrayList(u16) = .empty;
    for (entries.items) |entry| {
        const value = try std.unicode.utf8ToUtf16LeAllocZ(allocator, entry);
        try wide.appendSlice(allocator, value);
    }
    try wide.append(allocator, 0);
    return allocator.dupeZ(u16, wide.items[0 .. wide.items.len - 1]);
}

fn overlayEnvironment(allocator: std.mem.Allocator, entries: *std.ArrayList([]const u8), key: []const u8, value: []const u8) !void {
    const joined = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
    for (entries.items, 0..) |entry, index| if (environmentKeyEqual(entry, key)) { entries.items[index] = joined; return; };
    try entries.append(allocator, joined);
}

fn environmentKeyEqual(entry: []const u8, key: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    return std.ascii.eqlIgnoreCase(entry[0..equals], key);
}

fn asciiLess(a: []const u8, b: []const u8) bool {
    const length = @min(a.len, b.len);
    for (a[0..length], b[0..length]) |left, right| {
        const l = std.ascii.toLower(left); const r = std.ascii.toLower(right);
        if (l != r) return l < r;
    }
    return a.len < b.len;
}

fn watchRoot(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const wildcard = std.mem.indexOfAny(u8, input, "*?");
    const prefix = if (wildcard) |index| input[0..index] else input;
    const slash = std.mem.lastIndexOfAny(u8, prefix, "/\\");
    const root = if (wildcard == null) (if (slash) |index| input[0..index] else ".") else (if (slash) |index| input[0..index] else ".");
    if (root.len == 0) return allocator.dupe(u8, ".");
    return normalizePath(allocator, root);
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (path) |byte| try result.append(allocator, if (byte == '\\') '/' else byte);
    while (std.mem.startsWith(u8, result.items, "./")) _ = result.orderedRemove(0);
    while (result.items.len > 1 and result.items[result.items.len - 1] == '/') _ = result.pop();
    return result.toOwnedSlice(allocator);
}

fn joinLogical(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, root, ".")) return normalizePath(allocator, name);
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    return normalizePath(allocator, joined);
}

fn equalPath(a: []const u8, b: []const u8) bool { return std.ascii.eqlIgnoreCase(a, b); }
fn pathContains(parent: []const u8, child: []const u8) bool {
    if (equalPath(parent, child)) return true;
    return child.len > parent.len and std.ascii.eqlIgnoreCase(child[0..parent.len], parent) and child[parent.len] == '/';
}

fn globMatch(pattern_raw: []const u8, path_raw: []const u8) bool {
    var pattern_buffer: [1024]u8 = undefined;
    var path_buffer: [4096]u8 = undefined;
    if (pattern_raw.len > pattern_buffer.len or path_raw.len > path_buffer.len) return false;
    for (pattern_raw, 0..) |byte, index| pattern_buffer[index] = std.ascii.toLower(if (byte == '\\') '/' else byte);
    for (path_raw, 0..) |byte, index| path_buffer[index] = std.ascii.toLower(if (byte == '\\') '/' else byte);
    return glob(pattern_buffer[0..pattern_raw.len], path_buffer[0..path_raw.len]);
}

fn glob(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (pattern[0] == '*' and pattern.len >= 2 and pattern[1] == '*') {
        var next: usize = 2;
        while (next < pattern.len and pattern[next] == '*') : (next += 1) {}
        if (next < pattern.len and pattern[next] == '/') {
            if (glob(pattern[next + 1 ..], path)) return true;
            for (path, 0..) |byte, index| if (byte == '/' and glob(pattern[next + 1 ..], path[index + 1 ..])) return true;
            return false;
        }
        for (0..path.len + 1) |index| if (glob(pattern[next..], path[index..])) return true;
        return false;
    }
    if (pattern[0] == '*') {
        if (glob(pattern[1..], path)) return true;
        for (path, 0..) |byte, index| {
            if (byte == '/') break;
            if (glob(pattern[1..], path[index + 1 ..])) return true;
        }
        return false;
    }
    if (path.len == 0) return false;
    if (pattern[0] == '?') return path[0] != '/' and glob(pattern[1..], path[1..]);
    return pattern[0] == path[0] and glob(pattern[1..], path[1..]);
}

test "glob matching honors recursive and single-directory wildcards" {
    try std.testing.expect(globMatch("src/**/*.lua", "src/main.lua"));
    try std.testing.expect(globMatch("src/**/*.lua", "src/nested/main.lua"));
    try std.testing.expect(!globMatch("src/*.lua", "src/nested/main.lua"));
    try std.testing.expect(globMatch("assets/**", "assets/image.png"));
    try std.testing.expect(pathContains("dist/app", "dist/app/chunk.js"));
}
