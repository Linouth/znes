const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const memDumpOffset = @import("utils.zig").memDumpOffset;

const Cart = @import("Cart.zig");
const Mmu = @import("Mmu.zig");

const Cpu = struct {
    regs: struct {
        // General purpose
        a: u8,  // Accumulator
        x: u8,  // X index
        y: u8,  // Y index

        flag: u8,
        sp: u8,
        pc: u16,
    } = undefined,

    mmu: *Mmu,

    pub fn init(mmu: *Mmu) !Cpu {

        var cpu = Cpu {
            .mmu = mmu,
        };
        cpu.reset();

        return cpu;
    }

    fn reset(self: *Cpu) void {
        const pc_bytes: [2]u8 = .{self.mmu.getByte(0xfffc).?,
                                  self.mmu.getByte(0xfffd).?};

        self.regs = .{
            .a = 0,
            .x = 0,
            .y = 0,

            .flag = 0,
            .sp = 0,
            .pc = @as(u16, pc_bytes[1]) << 8 | pc_bytes[0],
        };
    }
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var arg_it = std.process.args();

    log.info("Running: {s}", .{arg_it.next(allocator)});

    const rom_filename = try (arg_it.next(allocator) orelse {
        log.warn("Expected first argument to hold the ROM filename", .{});
        return error.InvalidArgs;
    });

    var file = try std.fs.cwd().openFile(rom_filename, .{ .read = true });
    defer file.close();

    const cart = try Cart.init(allocator, &file.reader());
    defer cart.deinit();

    memDumpOffset(cart.prg_data[0..], 0xC000);

    var mmu = try Mmu.init(allocator);
    defer mmu.deinit();

    try mmu.load(cart);

    print("{x:0>2}\n", .{mmu.getByte(0xffff)});

    var cpu = Cpu.init(&mmu);
}
