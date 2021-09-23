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

pub fn dumpSurroundingHL(chunk: []const u8, addr: u32) void {
    const stdout = std.io.getStdOut().writer();

    const base = addr & 0xfffffff0;
    stdout.print("addr: {x}, base: {x}", .{addr, base}) catch {};

    const start_addr = base - 0x10;
    const c = chunk[start_addr .. base + 0x20];

    var index: usize = 0;
    while (index < c.len) : (index += 1) {
        if (index % 16 == 0) {
            _ = stdout.write("\n") catch {};
            stdout.print("{x:0>8}  ", .{index + start_addr}) catch {};
        } else if (index % 8 == 0) {
            _ = stdout.write(" ") catch {};
        }

        const poi = (start_addr + index) == addr;

        if (poi)
            stdout.print("\x1b[33;1m", .{}) catch {};
        stdout.print("{x:0>2} ", .{c[index]}) catch {};
        if (poi)
            stdout.print("\x1b[0m", .{}) catch {};
    }
    _ = stdout.write("\n") catch {};
}
