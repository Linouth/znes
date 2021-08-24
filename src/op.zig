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


// TODO: Some general method for setting the flags, instead of having to do it
// in every handler function
// Also: It might be better to Not set the flags when doing an operation, and
// instead storing the results of an operation and set it if a flag is actually
// needed.
// TODO: There needs to be a distinction between read and write functions that
// need to address memory. Right now, arg0 is sometimes the actual value, and
// sometimes the address we want to write to. This needs to be consistent.
//     Idea: union in Args to define whether it is an address, or a value.
//           Also, each Operation should hold a enum whether it reads or writes
//           memory. If it reads, we can pre-fetch the data from memory and pass
//           that. If it writes we could either pass the address and let the
//           function handle the writing, or return the data to write and
//           post-write to memory.

const Args = struct {
    arg0: ?u16 = null,
    arg1: ?u8  = null,
};

// TODO: This name can be better. An Operation instance is for **all**
// occurences of that opcode. OperationHandler or OperationType would be a
// better fit maybe.
const Operation = struct {
    const MemMode = enum {
        unused,
        read,
        write,
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

    mnemonic: []const u8,
    mem_mode: MemMode,
    addressing_mode: AddressingMode,
    bytes: u2,
    cycles: u3,

    /// Handler function
    handler: comptime ?fn (cpu: *Cpu, op: Operation, args: *Args) void = null,

    /// Evaluate this operation. This will modify the Cpu object, an possibly
    /// access the Mmu.
    ///
    /// This function will read the required values from memory.
    /// The general flow is as follows:
    /// 1. If the instruction uses memory in any way, decode the address as
    ///    supposed to in the specific addressing mode.
    /// 2. If the instruction reads from memory, set the argument for the handler
    ///    to the data in memory. Otherwise the argument is null.
    /// 3. Run this instruction's specific handler
    /// 4. If the instruction writes to memory, write the arg byte from the
    ///    handler to the address decoded in (1).
    pub fn eval(self: Operation, cpu: *Cpu) !void {
        if (self.handler) |handler| {

            // Read all bytes belonging to this operation
            var bytes: [2]u8 = undefined;
            var i: u8 = 0;
            while (i < self.bytes - 1) : (i += 1) {
                bytes[i] = cpu.readMemory();
            }

            const addr: u16 = switch (self.addressing_mode) {
                .zero_page => bytes[0],
                .zero_page_x => bytes[0] +% cpu.regs.x,
                .zero_page_y => bytes[0] +% cpu.regs.y,

                .absolute => @as(u16, bytes[0]) << 8 | bytes[1],
                .absolute_x => (@as(u16, bytes[0]) << 8 | bytes[1]) + cpu.regs.x,
                .absolute_y => (@as(u16, bytes[0]) << 8 | bytes[1]) + cpu.regs.y,

                .indirect => blk: {
                    const base = @as(u16, bytes[0]) << 8 | bytes[1];
                    const lsb = try cpu.mmu.readByte(base);
                    const msb = try cpu.mmu.readByte(base + 1);
                    break :blk @as(u16, msb) << 8 | lsb;
                },
                .indexed_indirect => blk: {
                    const lsb = try cpu.mmu.readByte(bytes[0] +% cpu.regs.x);
                    const msb = try cpu.mmu.readByte(bytes[0] +% cpu.regs.x + 1);
                    break :blk @as(u16, msb) << 8 | lsb;
                },
                .indirect_indexed => blk: {
                    const lsb = try cpu.mmu.readByte(bytes[0]);
                    const msb = try cpu.mmu.readByte(bytes[0] + 1);
                    break :blk @as(u16, msb) << 8 | lsb;
                },

                else => 0,
            };

            var args: Args = if (self.mem_mode == .read) switch (self.addressing_mode) {
                .implied => Args{},
                .accumulator => Args{ .arg0 = cpu.regs.a },
                .immediate, .relative => Args{ .arg0 = bytes[0] },

                else => Args{ .arg0 = try cpu.mmu.readByte(addr) },
            } else Args{};

            print("{}\n", .{args});

            // TODO: Try inline this with @call
            handler(cpu, self, &args);

            if (self.mem_mode == .write) {
                try cpu.mmu.writeByte(addr, @intCast(u8, args.arg0.?));
            }
        } else {
            return OperationError.UnimplementedOperation;
        }
    }
};

/// LUT for 6502 opcodes
const opcodes = comptime blk: {
    // This block generates the LUT for all opcodes

    var ret: [0x100]?Operation = .{null} ** 0x100;

    const instruction_definitions = .{
        // Add with Carry
        .{ .mnemonic = "ADC", .mem_mode = .read, .opcodes = .{
            .{ 0x69, .{ .addressing_mode = .immediate,          .bytes = 2, .cycles = 2 } },
            .{ 0x65, .{ .addressing_mode = .zero_page,          .bytes = 2, .cycles = 3 } },
            .{ 0x75, .{ .addressing_mode = .zero_page_x,        .bytes = 2, .cycles = 4 } },
            .{ 0x6D, .{ .addressing_mode = .absolute,           .bytes = 3, .cycles = 4 } },
            .{ 0x7D, .{ .addressing_mode = .absolute_x,         .bytes = 3, .cycles = 4 } },
            .{ 0x79, .{ .addressing_mode = .absolute_y,         .bytes = 3, .cycles = 4 } },
            .{ 0x61, .{ .addressing_mode = .indexed_indirect,   .bytes = 2, .cycles = 6 } },
            .{ 0x71, .{ .addressing_mode = .indirect_indexed,   .bytes = 2, .cycles = 5 } },
        }},

        // Clear Decimal Mode
        .{ .mnemonic = "CLD", .mem_mode = .unused, .opcodes = .{
            .{ 0xD8, .{ .addressing_mode = .implied,            .bytes = 1, .cycles = 2 } },
        }},

        // Load Accumulator
        .{ .mnemonic = "LDA", .mem_mode = .read, .opcodes = .{
            .{ 0xA9, .{ .addressing_mode = .immediate,          .bytes = 2, .cycles = 2 } },
            .{ 0xAD, .{ .addressing_mode = .absolute,           .bytes = 3, .cycles = 4 } },
        }},

        // Load X Register
        .{ .mnemonic = "LDX", .mem_mode = .read, .opcodes = .{
            .{ 0xA2, .{ .addressing_mode = .immediate,          .bytes = 2, .cycles = 2 } },
        }},

        // Load Y Register
        .{ .mnemonic = "LDY", .mem_mode = .read, .opcodes = .{
            .{ 0xA0, .{ .addressing_mode = .immediate,          .bytes = 2, .cycles = 2 } },
        }},

        // Store Accumulator
        .{ .mnemonic = "STA", .mem_mode = .write, .opcodes = .{
            .{ 0x8D, .{ .addressing_mode = .absolute,           .bytes = 3, .cycles = 4 } },
        }},

        // Store X Register
        .{ .mnemonic = "STX", .mem_mode = .write, .opcodes = .{
            .{ 0x8E, .{ .addressing_mode = .absolute,           .bytes = 3, .cycles = 4 } },
        }},

        // Store Y Register
        .{ .mnemonic = "STY", .mem_mode = .write, .opcodes = .{
            .{ 0x8C, .{ .addressing_mode = .absolute,           .bytes = 3, .cycles = 4 } },
        }},

        // Set Interrupt Disable
        .{ .mnemonic = "SEI", .mem_mode = .unused, .opcodes = .{
            .{ 0x78, .{ .addressing_mode = .implied,            .bytes = 1, .cycles = 2 } },
        }},

        // Transfer A to Stack Pointer
        .{ .mnemonic = "TAS", .mem_mode = .unused, .opcodes = .{
            .{ 0x8A, .{ .addressing_mode = .implied,            .bytes = 1, .cycles = 2 } },
        }},

        // Transfer X to Stack Pointer
        .{ .mnemonic = "TXS", .mem_mode = .unused, .opcodes = .{
            .{ 0x9A, .{ .addressing_mode = .implied,            .bytes = 1, .cycles = 2 } },
        }},

        // Transfer Y to Stack Pointer
        .{ .mnemonic = "TYS", .mem_mode = .unused, .opcodes = .{
            .{ 0x98, .{ .addressing_mode = .implied,            .bytes = 1, .cycles = 2 } },
        }},
    };

    for (instruction_definitions) |instruction| {
        // Retrieve this instruction's handle function
        const handle_fn = "handle" ++ instruction.mnemonic;
        const field: ?@TypeOf(handleSEI) = if (@hasDecl(@This(), handle_fn)) @field(@This(), handle_fn) else null;

        // Go over each opcode belonging to this instruction
        for (instruction.opcodes) |opcode| {
            ret[opcode[0]] = Operation {
                .mnemonic = instruction.mnemonic,
                .mem_mode = instruction.mem_mode,
                .addressing_mode = opcode[1].addressing_mode,
                .bytes = opcode[1].bytes,
                .cycles = opcode[1].cycles,
            };

            // Assign operation implementation function if available.
            if (field) |f| {
                ret[opcode[0]].?.handler = field;
            }
        }
    }

    break :blk ret;
};

/// Return the Operation belonging to an opcode, if it is a valid opcode.
pub fn decode(byte: u8) !Operation {
    return opcodes[byte] orelse OperationError.UnknownOpcode;
}

fn handleSEI(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.p.flag.i = true;
}

fn handleLDA(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.a = @intCast(u8, args.arg0.?);

}

fn handleLDX(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.x = @intCast(u8, args.arg0.?);

}

fn handleSTA(cpu: *Cpu, op: Operation, args: *Args) void {
    //cpu.mmu.writeByte(args.arg0.?, args.arg1.?) catch unreachable;
    args.arg0 = cpu.regs.a;
}

fn handleCLD(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.p.flag.d = false;
}

fn handleTAS(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.sp = @intCast(u8, cpu.regs.a);
}

fn handleTXS(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.sp = @intCast(u8, cpu.regs.x);
}

fn handleTYS(cpu: *Cpu, op: Operation, args: *Args) void {
    cpu.regs.sp = @intCast(u8, cpu.regs.y);
}
