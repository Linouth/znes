const std = @import("std");

const utils = @import("utils.zig");
const op = @import("op.zig");

const Mmu = @import("Mmu.zig");
const Cpu = @This();

regs: struct {
    const Regs = @This();

    // General purpose
    a: u8,  // Accumulator
    x: u8,  // X index
    y: u8,  // Y index

    p: extern union {
        raw: u8,
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

    pub fn print(self: *Regs) void {
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

nmi: *bool,

ticks: u32 = 0,

pub fn init(mmu: *Mmu, nmi: *bool) Cpu {

    var cpu = Cpu {
        .regs = .{
            .a = 0,
            .x = 0,
            .y = 0,
            .p = .{ .raw = 0x34 },
            .sp = 0xfd,
            .pc = undefined,
            .prev = undefined,
        },
        .mmu = mmu,
        .nmi = nmi,
    };
    cpu.reset();

    return cpu;
}

fn reset(self: *Cpu) void {
    var pc_bytes: [2]u8 = undefined;
    self.mmu.readBytes(0xfffc, &pc_bytes) catch unreachable;

    self.regs.p = .{ .raw = self.regs.p.raw | 0x04 };
    self.regs.sp = self.regs.sp - 3;
    self.regs.pc = @as(u16, pc_bytes[1]) << 8 | pc_bytes[0];

    self.ticks = 0;
}

pub fn tick(self: *Cpu) !void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("\n", .{}) catch unreachable;
    self.regs.print();

    if (self.nmi.*) {
        // Non-maskable-interrupt triggered

        // Push return address and CPU status register to the stack
        self.push(@truncate(u8, self.regs.pc >> 8));
        self.push(@truncate(u8, self.regs.pc));
        self.push(self.regs.p.raw);

        self.nmi.* = false;
        var bytes: [2]u8 = undefined;
        try self.mmu.readBytes(0xfffa, &bytes);
        const addr = bytes[0] | (@as(u16, bytes[1]) << 8);
        self.regs.pc = addr;
    }

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

pub fn push(self: *Cpu, data: u8) void {
    const sp = @as(u16, 0x0100) | self.regs.sp;
    self.mmu.writeByte(sp, data) catch unreachable;
    self.regs.sp -= 1;
}

pub fn pop(self: *Cpu) u8 {
    self.regs.sp += 1;
    const sp = @as(u16, 0x0100) | self.regs.sp;
    const data = self.mmu.readByte(sp) catch unreachable;
    return data;
}

pub fn stackPrint(self: Cpu) void {
    var buf: [0x100]u8 = undefined;
    self.mmu.readBytes(0x100, &buf) catch unreachable;
    utils.memDumpOffset(&buf, 0x100);
}
