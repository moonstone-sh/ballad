const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .windows) {
        try std.io.getStdErr().writer().print("ballad-watch is a native Windows helper\n", .{});
        return error.UnsupportedOperatingSystem;
    }
    return @import("windows.zig").main(init);
}

test {
    _ = manifest;
}
