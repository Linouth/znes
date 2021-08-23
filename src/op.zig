const std = @import("std");

const print = std.debug.print;

const Cpu = @import("main.zig").Cpu;


const OperationError = error {
    /// This operation is known but has not yet been implemented.
    UnimplementedOperation,

    /// Tried to handle an unknown opcode.
    UnknownOpcode,

    // This addressing mode is not yet implemented.
    UnimplementedAddressingMode,
};

/// http://obelisk.me.uk/6502/addressing.html#IDX
const AddressingMode = enum {
    implied,
    accumulator,
    immediate,
    zero_page,
    zero_page_x,
    zero_page_y,
    relative,
    absolute,
    absolute_x,
    absolute_y,
    indirect,
    indexed_indirect,
    indirect_indexed,
};

//fn Instruction(comptime mnemonic: []const u8, comptime opcode: u8, 

// TODO: Some general method for setting the flags, instead of having to do it
// in every handler function
// Also: It might be better to Not set the flags when doing an operation, and
// instead storing the results of an operation and set it if a flag is actually
// needed.
// TODO: There needs to be a distinction between read and write functions that
// need to address memory. Right now, arg0 is sometimes the actual value, and
// sometimes the address we want to write to. This needs to be consistent.

const Args = struct {
    arg0: ?u16 = null,
    arg1: ?u8  = null,
};

const Operation = struct {
    mnemonic: []const u8,
    addressing_mode: AddressingMode,
    bytes: u2,
    cycles: u3,

    /// Handler function
    handler: ?fn (cpu: *Cpu, op: Operation, args: Args) void = null,

    pub fn eval(self: *Operation, cpu: *Cpu) !void {
        if (self.handler) |handler| {

            // Read all bytes belonging to this operation
            var bytes: [2]u8 = undefined;
            var i: u8 = 0;
            while (i < self.bytes - 1) : (i += 1) {
                bytes[i] = cpu.readMemory();
            }

            const args: Args = switch (self.addressing_mode) {
                AddressingMode.implied => .{},
                AddressingMode.accumulator => .{ .arg0 = cpu.regs.a },
                AddressingMode.immediate => .{ .arg0 = bytes[0] },
                AddressingMode.zero_page =>
                    .{ .arg0 = try cpu.mmu.readByte(bytes[0]) },

                AddressingMode.absolute =>
                    .{ .arg0 = @as(u16, bytes[0]) << 8 | bytes[1], .arg1 = cpu.regs.a },

                else => return OperationError.UnimplementedAddressingMode,
            };

            print("{}\n", .{args});
            handler(cpu, self.*, args);
        } else {
            return OperationError.UnimplementedOperation;
        }
    }
};

/// LUT for 6502 opcodes
const opcodes = comptime blk: {
    // This block generates the LUT for all opcodes

    var ret: [0x100]?Operation = .{null} ** 0x100;

    const m = AddressingMode;
    const opcode_definitions = .{
        .{ 0xEA, .{ .mnemonic = "NOP", .addressing_mode = m.implied,            .bytes = 1, .cycles = 2 } },

        // Add with carry
        .{ 0x69, .{ .mnemonic = "ADC", .addressing_mode = m.immediate,          .bytes = 2, .cycles = 2 } },
        .{ 0x65, .{ .mnemonic = "ADC", .addressing_mode = m.zero_page,          .bytes = 2, .cycles = 3 } },
        .{ 0x75, .{ .mnemonic = "ADC", .addressing_mode = m.zero_page_x,        .bytes = 2, .cycles = 4 } },
        .{ 0x6d, .{ .mnemonic = "ADC", .addressing_mode = m.absolute,           .bytes = 3, .cycles = 4 } },
        .{ 0x7d, .{ .mnemonic = "ADC", .addressing_mode = m.absolute_x,         .bytes = 3, .cycles = 4 } },
        .{ 0x79, .{ .mnemonic = "ADC", .addressing_mode = m.absolute_y,         .bytes = 3, .cycles = 4 } },
        .{ 0x61, .{ .mnemonic = "ADC", .addressing_mode = m.indexed_indirect,   .bytes = 2, .cycles = 6 } },
        .{ 0x71, .{ .mnemonic = "ADC", .addressing_mode = m.indirect_indexed,   .bytes = 2, .cycles = 5 } },

        // Clear decimal mode
        .{ 0xd8, .{ .mnemonic = "CLD", .addressing_mode = m.implied,            .bytes = 1, .cycles = 2 } },

        // Load Accumulator
        .{ 0xa9, .{ .mnemonic = "LDA", .addressing_mode = m.immediate,          .bytes = 2, .cycles = 2 } },
        .{ 0xad, .{ .mnemonic = "LDA", .addressing_mode = m.absolute,           .bytes = 3, .cycles = 4 } },

        // Load x register
        .{ 0xa2, .{ .mnemonic = "LDX", .addressing_mode = m.immediate,          .bytes = 2, .cycles = 2 } },

        // Store accumulator
        .{ 0x8d, .{ .mnemonic = "STA", .addressing_mode = m.absolute,           .bytes = 3, .cycles = 4 } },

        // Set interrupt disable
        .{ 0x78, .{ .mnemonic = "SEI", .addressing_mode = m.implied,            .bytes = 1, .cycles = 2 } },

        // Transfer A to Stack Pointer
        .{ 0x8a, .{ .mnemonic = "TAS", .addressing_mode = m.implied,            .bytes = 1, .cycles = 2 } },

        // Transfer X to Stack Pointer
        .{ 0x9a, .{ .mnemonic = "TXS", .addressing_mode = m.implied,            .bytes = 1, .cycles = 2 } },

        // Transfer Y to Stack Pointer
        .{ 0x98, .{ .mnemonic = "TYS", .addressing_mode = m.implied,            .bytes = 1, .cycles = 2 } },
    };

    for (opcode_definitions) |code| {
        ret[code[0]] = code[1];

        // Assign operation implementation function if available.
        const handle_fn = "handle" ++ code[1].mnemonic;
        if (@hasDecl(@This(), handle_fn)) {
            const this = @This();
            ret[code[0]].?.handler = @field(this, handle_fn);
        }
    }

    break :blk ret;
};

/// Return the Operation belonging to an opcode, if it is a valid opcode.
pub fn decode(byte: u8) !Operation {
    return opcodes[byte] orelse OperationError.UnknownOpcode;
}

//fn handleSEI(op: Operation, cpu: *Cpu) void {
fn handleSEI(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.p.flag.i = true;
}

fn handleLDA(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.a = @intCast(u8, args.arg0.?);

}

fn handleLDX(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.x = @intCast(u8, args.arg0.?);

}

fn handleSTA(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.mmu.writeByte(args.arg0.?, args.arg1.?) catch unreachable;
}

fn handleCLD(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.p.flag.d = false;
}

fn handleTAS(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.sp = @intCast(u8, cpu.regs.a);
}

fn handleTXS(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.sp = @intCast(u8, cpu.regs.x);
}

fn handleTYS(cpu: *Cpu, op: Operation, args: Args) void {
    cpu.regs.sp = @intCast(u8, cpu.regs.y);
}
