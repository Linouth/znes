const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const memDumpOffset = @import("utils.zig").memDumpOffset;

const Cart = @import("Cart.zig");
const Mmu = @import("Mmu.zig");

const Cpu = struct {
    const CpuError = error {
        /// Tried to handle an unknown opcode
        UnhandledInstruction,
    };

    regs: struct {
        // General purpose
        a: u8,  // Accumulator
        x: u8,  // X index
        y: u8,  // Y index

        p: extern union {
            all: u8,
            flag: packed struct {
                c: bool,  // Carry flag
                z: bool,  // Zero flag
                i: bool,  // Interrupt disable flag
                d: bool,  // Decimal mode flag
                b: bool,  // Break flag
                _: bool,  // Unused, always 1 (?)
                v: bool,  // oVerflow flag
                n: bool,  // Negative flag
            },
        },
        sp: u8,
        pc: u16,
    } = undefined,

    mmu: *Mmu,

    timer: u32 = 0,

    pub fn init(mmu: *Mmu) Cpu {

        var cpu = Cpu {
            .mmu = mmu,
        };
        cpu.reset();

        return cpu;
    }

    fn reset(self: *Cpu) void {
        var pc_bytes: [2]u8 = undefined;
        self.mmu.getBytes(0xfffc, &pc_bytes) catch unreachable;

        self.regs = .{
            .a = 0,
            .x = 0,
            .y = 0,

            .p = .{ .all = 0b00100000 },
            .sp = 0,
            .pc = @as(u16, pc_bytes[1]) << 8 | pc_bytes[0],
        };

        self.timer = 0;
    }

    fn tick(self: *Cpu) !void {
        const inst = self.mmu.getByte(self.regs.pc) catch unreachable;

        print("CPU status: {any}\n", .{self.regs.p.flag});
        print("{x:0>2}\n", .{inst});

        try self.decode(inst);

        self.timer += 1;
    }

    fn decode(self: *Cpu, opcode: u8) !void {
        switch(opcode) {
            0x78 => {
                self.regs.p.flag.i = true;
                self.regs.pc += 1;
            },
            else => return CpuError.UnhandledInstruction,
        }
    }
};

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

    memDumpOffset(cart.prg_data[0..], 0xC000);

    var mmu = try Mmu.init(allocator);
    defer mmu.deinit();

    try mmu.load(cart);

    var cpu = Cpu.init(&mmu);

    while (cpu.tick()) |_| {

    } else |err| {
        if (err == error.UnhandledInstruction) {
            log.err("Unhandled instruction encountered: {x:0>2}",
                .{try cpu.mmu.getByte(cpu.regs.pc)});
        }
    }
}
