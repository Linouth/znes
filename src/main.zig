const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const memDumpOffset = @import("utils.zig").memDumpOffset;

const Cart = @import("Cart.zig");
const Mmu = @import("Mmu.zig");
const Ppu = @import("Ppu.zig");

const op = @import("op.zig");


pub const Cpu = struct {
    regs: struct {
        const Regs = @This();

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

        prev: u8,  // Meta register, holds the result of the previous operation

        fn print(self: *Regs) void {
            const stdout = std.io.getStdOut().writer();

            stdout.print("Regs:\t", .{}) catch unreachable;

            const flag = self.p.flag;
            stdout.print("N: {}, V: {}, B: {}, D: {}, I: {}, Z: {}, C: {}\n",
                //.{ flag.n, flag.v, flag.b, flag.d, flag.i, flag.z, flag.c }) catch unreachable;
                .{ self.n(), self.v(), flag.b, flag.d, flag.i, self.z(), self.c() }) catch unreachable;

            stdout.print("\tA: {x:0>2}, X: {x:0>2}, Y: {x:0>2}\t SP: {x:0>2}, PC: {x:0>4}\n",
                .{ self.a, self.x, self.y, self.sp, self.pc }) catch unreachable;
        }

        pub inline fn c(self: *Regs) bool {
            // TODO: Implement this
            //@panic("regs.v() is not implemented yet.");
            return self.p.flag.c;
        }

        pub inline fn z(self: *Regs) bool {
            self.p.flag.z = (self.prev == 0);
            return self.p.flag.z;
        }

        pub inline fn v(self: *Regs) bool {
            // TODO: Implement this...
            //@panic("regs.v() is not implemented yet.");
            return self.p.flag.v;
        }

        pub inline fn n(self: *Regs) bool {
            self.p.flag.n = (self.prev & 0x80) > 0;
            return self.p.flag.n;
        }
    },

    mmu: *Mmu,

    ticks: u32 = 0,

    pub fn init(mmu: *Mmu) Cpu {

        var cpu = Cpu {
            .regs = .{
                .a = 0,
                .x = 0,
                .y = 0,
                .p = .{ .all = 0x34 },
                .sp = 0xfd,
                .pc = undefined,
                .prev = undefined,
            },
            .mmu = mmu,
        };
        cpu.reset();

        return cpu;
    }

    fn reset(self: *Cpu) void {
        var pc_bytes: [2]u8 = undefined;
        self.mmu.readBytes(0xfffc, &pc_bytes) catch unreachable;

        self.regs.p = .{ .all = self.regs.p.all | 0x04 };
        self.regs.sp = self.regs.sp - 3;
        self.regs.pc = @as(u16, pc_bytes[1]) << 8 | pc_bytes[0];

        self.ticks = 0;
    }

    fn tick(self: *Cpu) !void {
        const stdout = std.io.getStdOut().writer();

        stdout.print("\n", .{}) catch unreachable;
        self.regs.print();

        const byte = self.readMemory();

        var opcode = try op.decode(byte);

        stdout.print("Operation: ${x:0>2}: {s}; instruction_type: {}, addr_mode: {}, bytes: {}, cycles: {}\n",
            .{ byte, opcode.mnemonic, opcode.instruction_type, opcode.addressing_mode, opcode.bytes, opcode.cycles }) catch unreachable;
        stdout.print("Ticks: {}\n", .{self.ticks}) catch unreachable;

        try opcode.eval(self);

        self.ticks += 1;
    }

    pub fn readMemory(self: *Cpu) u8 {
        const byte = self.mmu.readByte(self.regs.pc) catch unreachable;
        self.regs.pc += 1;

        return byte;
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

    // TODO: Temporary
    var ram = try allocator.alloc(u8, 0x800);
    var ppu = Ppu.init();
    //var ppu_regs: [8]u8 = .{
    //    0,          // PPUCTRL
    //    0b00010001, // PPUMASK
    //    0b00000001, // PPUSTATUS
    //    0,          // OAMADDR
    //    0,          // OAMDATA
    //    0,          // PPUSCROLL
    //    0,          // PPUADDR
    //    0,          // OAMDMA
    //};
    var apu_io_regs: [0x18]u8 = .{0} ** 0x18;
    try mmu.mmap(ram, 0x0000, 0x2000);
    try mmu.mmap(@ptrCast([*]u8, &ppu.ports)[0..8], 0x2000, 0x4000);
    try mmu.mmap(&apu_io_regs, 0x4000, 0x4018);

    var cpu = Cpu.init(&mmu);

    while (cpu.tick()) |_| {

        ppu.tick();

        //if (cpu.regs.pc == 0xc313)
        //if (cpu.regs.pc == 0xc321)
        //    break;

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
    memDumpOffset(&buf, 0);
}
