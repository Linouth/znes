const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const utils = @import("utils.zig");

const Cart = @import("Cart.zig");
const Mmu = @import("Mmu.zig");
const Ppu = @import("Ppu.zig");
const Cpu = @import("Cpu.zig");


pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var arg_it = std.process.args();

    log.info("Running: {s}", .{arg_it.next(allocator)});

    const rom_filename = try (arg_it.next(allocator) orelse {
        log.err("Expected first argument to hold the ROM filename", .{});
        return error.InvalidArgs;
    });

    var file = try std.fs.cwd().openFile(rom_filename, .{ .read = true });
    defer file.close();

    const cart = try Cart.init(allocator, &file.reader());
    defer cart.deinit();

    utils.memDumpOffset(cart.prg_data[0..], 0xC000);

    var mmu = try Mmu.init(allocator);
    defer mmu.deinit();

    try mmu.load(cart);

    var nmi: bool = false;

    // TODO: Temporary
    var ram = try allocator.alloc(u8, 0x800);
    var ppu = Ppu.init(&nmi);
    var apu_io_regs: [0x18]u8 = .{0} ** 0x18;
    try mmu.mmap(.{ .slice = ram, .start = 0x0000, .end = 0x2000, .writable = true });
    try mmu.mmap(.{
        .slice = @ptrCast([*]u8, &ppu.ports)[0..8],
        .start = 0x2000,
        .end = 0x4000,
        .writable = true,
        .callback = blk: {
            // NOTE: For some reason .ctx and .func are null if I init Callback
            // without first saving it to a variable.
            const cb = Mmu.Callback {
                .ctx = &ppu,
                .func = Ppu.memoryCallback,
            };
            break :blk cb;
        },
    });
    try mmu.mmap(.{ .slice = &apu_io_regs, .start = 0x4000, .end = 0x4018, .writable = true });
    mmu.sortMaps();

    var cpu = Cpu.init(&mmu, &nmi);

    while (cpu.tick()) |_| {

        var ii: usize = 0;
        while (ii < 3) : (ii += 1) {
            ppu.tick();
        }

        // The end of the NMI handler
        //if (cpu.regs.pc == 0xc190) {
        //    print("NMI Handler finished(..?)\n", .{});
        //    break;
        //}
    } else |err| {
        switch (err) {
            error.UnknownOpcode => {
                log.err("Unknown opcode encountered: ${x:0>2}",
                    .{try cpu.mmu.readByte(cpu.regs.pc - 1)});
            },

            error.UnimplementedOperation => {
                log.err("Unimplemented operation encountered: ${x:0>2}",
                    .{try cpu.mmu.readByte(cpu.regs.pc - 1)});
            },

            else => log.err("CPU ran into an unknown error: {}", .{err}),
        }

        cpu.regs.print();
    }

    var buf: [0x210]u8 = undefined;
    try mmu.readBytes(0x0000, &buf);
    utils.memDumpOffset(&buf, 0);
}
