const std = @import("std");

pub fn memDump(chunk: []const u8) void {
    memDumpOffset(chunk, 0);
}

pub fn memDumpOffset(chunk: []const u8, offset: u32) void {
    const stdout = std.io.getStdOut().writer();

    var index: usize = 0;
    while (index < chunk.len) : (index += 1) {
        if (index % 16 == 0) {
            _ = stdout.write("\n") catch {};
            stdout.print("{x:0>8}  ", .{index + offset}) catch {};
        } else if (index % 8 == 0) {
            _ = stdout.write(" ") catch {};
        }

        stdout.print("{x:0>2} ", .{chunk[index]}) catch {};
    }
    _ = stdout.write("\n") catch {};
}
