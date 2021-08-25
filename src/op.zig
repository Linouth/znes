const std = @import("std");

const print = std.debug.print;

const Cpu = @import("main.zig").Cpu;


const OperationError = error {
    /// This operation is known but has not yet been implemented.
    UnimplementedOperation,

    /// Tried to handle an unknown opcode.
    UnknownOpcode,
};

const ArgType = enum {
    none,
    u8,
    u16,
};

const Arg = union(ArgType) {
    none,
    u8: u8,
    u16: u16,
};

// TODO: This name can be better. An Operation instance is for **all**
// occurences of that opcode. OperationHandler or OperationType would be a
// better fit maybe.
const Operation = struct {
    // TODO: Check if these types are still necessary. I should be able to get
    // the required info from the addressing mode. And writing to memory is
    // now flagged by returning a value from the handle function.
    const InstructionType = enum {
        /// Any operation with as main function to set a flag.
        flags_set,

        /// Any operation with as main function to read from memory.
        memory_read,

        /// Any operation with as main function to write to memory.
        memory_write,

        /// Any operation with as main function to transfer a value between
        /// registers.
        register_modify,

        /// Any operation that changes PC directly (e.g. Jump and Branch).
        jump,
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
    instruction_type: InstructionType,
    addressing_mode: AddressingMode,
    bytes: u2,
    cycles: u3,

    /// Handler function
    handler: comptime ?fn (cpu: *Cpu, input: Arg) ?u8 = null,

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
        const stdout = std.io.getStdOut().writer();
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

                .absolute => @as(u16, bytes[1]) << 8 | bytes[0],
                .absolute_x => (@as(u16, bytes[1]) << 8 | bytes[0]) + cpu.regs.x,
                .absolute_y => (@as(u16, bytes[1]) << 8 | bytes[0]) + cpu.regs.y,

                .indirect => blk: {
                    const base = @as(u16, bytes[1]) << 8 | bytes[0];
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
                    break :blk (@as(u16, msb) << 8 | lsb) + cpu.regs.y;
                },

                else => 0,
            };

            var arg: Arg = if (self.instruction_type == .memory_read) switch (self.addressing_mode) {
                .implied => Arg{ .none = {} },
                .accumulator => Arg{ .u8 = cpu.regs.a },
                .immediate, .relative => Arg{ .u8 = bytes[0] },

                else => Arg{ .u8 = try cpu.mmu.readByte(addr) },
            } else if (self.instruction_type == .jump) switch (self.addressing_mode) {
                .relative => Arg{ .u8 = bytes[0] },
                .absolute => Arg{ .u16 = addr },  // Tricky for combination, in mem read read this addr; in jump this is the arg. Rest is easy
                .indirect => Arg{ .u8 = try cpu.mmu.readByte(addr) },

                else => unreachable,
            } else Arg{ .none = {} };

            //print("{}\n", .{arg});
            stdout.print("Bytes: 0x{x:0>2} 0x{x:0>2}\n", .{bytes[0], bytes[1]}) catch unreachable;
            stdout.print("Arg: {}\n", .{arg}) catch unreachable;

            // TODO: Try inline this with @call
            const result = handler(cpu, arg);

            if (result) |res| {
                stdout.print("Writing 0x{x:0>2} to address 0x{x:0>4}\n", .{res, addr}) catch unreachable;
                try cpu.mmu.writeByte(addr, res);
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
        .{ .mnemonic = "ADC", .instruction_type = .memory_read, .opcodes = .{
            .{0x69, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0x65, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x75, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x6D, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0x7D, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0x79, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0x61, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0x71, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Logical AND
        .{ .mnemonic = "AND", .instruction_type = .memory_read, .opcodes = .{
            .{0x29, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0x25, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x35, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x2D, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0x3D, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0x39, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0x21, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0x31, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Branch if Equal
        .{ .mnemonic = "BEQ", .instruction_type = .jump, .opcodes = .{
            .{0xF0, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Branch if Minus
        .{ .mnemonic = "BMI", .instruction_type = .jump, .opcodes = .{
            .{0x30, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Branch if Not Equal
        .{ .mnemonic = "BNE", .instruction_type = .jump, .opcodes = .{
            .{0xD0, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Branch if Positive
        .{ .mnemonic = "BPL", .instruction_type = .jump, .opcodes = .{
            .{0x10, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Clear Decimal Mode
        .{ .mnemonic = "CLD", .instruction_type = .flags_set, .opcodes = .{
            .{0xD8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Compare
        .{ .mnemonic = "CMP", .instruction_type = .memory_read, .opcodes = .{
            .{0xC9, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xC5, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xD5, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0xCD, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0xDD, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0xD9, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0xC1, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0xD1, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Compare X Register
        .{ .mnemonic = "CPX", .instruction_type = .memory_read, .opcodes = .{
            .{0xE0, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xE4, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xEC, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
        }},

        // Compare Y Register
        .{ .mnemonic = "CPY", .instruction_type = .memory_read, .opcodes = .{
            .{0xC0, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xC4, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xCC, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
        }},

        // Decrement Memory
        .{ .mnemonic = "DEC", .instruction_type = .memory_read, .opcodes = .{
            .{0xC6, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 5 }},
            .{0xD6, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 6 }},
            .{0xCE, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
            .{0xDE, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 7 }},
        }},

        // Decrement X Register
        .{ .mnemonic = "DEX", .instruction_type = .register_modify, .opcodes = .{
            .{0xCA, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Decrement Y Register
        .{ .mnemonic = "DEY", .instruction_type = .register_modify, .opcodes = .{
            .{0x88, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Increment X Register
        .{ .mnemonic = "INC", .instruction_type = .memory_read, .opcodes = .{
            .{0xE6, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 5 }},
            .{0xF6, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 6 }},
            .{0xEE, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
            .{0xFE, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 7 }},
        }},

        // Increment X Register
        .{ .mnemonic = "INX", .instruction_type = .register_modify, .opcodes = .{
            .{0xE8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Increment Y Register
        .{ .mnemonic = "INY", .instruction_type = .register_modify, .opcodes = .{
            .{0xC8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Jump
        .{ .mnemonic = "JMP", .instruction_type = .jump, .opcodes = .{
            .{0x4C, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 3 }},
            .{0x6C, .{ .addressing_mode = .indirect,            .bytes = 3, .cycles = 5 }},
        }},

        // Jump to Subroutine
        .{ .mnemonic = "JSR", .instruction_type = .jump, .opcodes = .{
            .{0x20, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
        }},

        // Load Accumulator
        .{ .mnemonic = "LDA", .instruction_type = .memory_read, .opcodes = .{
            .{0xA9, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xA5, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xB5, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0xAD, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0xBD, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0xB9, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0xA1, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0xB1, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Load X Register
        .{ .mnemonic = "LDX", .instruction_type = .memory_read, .opcodes = .{
            .{0xA2, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
        }},

        // Load Y Register
        .{ .mnemonic = "LDY", .instruction_type = .memory_read, .opcodes = .{
            .{0xA0, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xA4, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xB4, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0xAC, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0xBC, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
        }},

        // Return from Subroutine
        .{ .mnemonic = "RTS", .instruction_type = .jump, .opcodes = .{
            .{0x60, .{ .addressing_mode = .absolute,            .bytes = 1, .cycles = 6 }},
        }},

        // Store Accumulator
        .{ .mnemonic = "STA", .instruction_type = .memory_write, .opcodes = .{
            .{0x85, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x95, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x8D, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0x9D, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 5 }},
            .{0x99, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 5 }},
            .{0x81, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0x91, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 6 }},
        }},

        // Store X Register
        .{ .mnemonic = "STX", .instruction_type = .memory_write, .opcodes = .{
            .{0x86, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x96, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x8E, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
        }},

        // Store Y Register
        .{ .mnemonic = "STY", .instruction_type = .memory_write, .opcodes = .{
            .{0x84, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x94, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x8C, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
        }},

        // Set Interrupt Disable
        .{ .mnemonic = "SEI", .instruction_type = .flags_set, .opcodes = .{
            .{0x78, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Transfer X to Stack Pointer
        .{ .mnemonic = "TXS", .instruction_type = .register_modify, .opcodes = .{
            .{0x9A, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Transfer Y to Accumulator
        .{ .mnemonic = "TYA", .instruction_type = .register_modify, .opcodes = .{
            .{0x98, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
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
                //.mem_mode = instruction.mem_mode,
                .instruction_type = instruction.instruction_type,
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

inline fn calcBranchOffset(pc: u16, offset: u8) u16 {
    // There HAS to be a better way to do this... (u8 + i8)
    return if (offset & 0x80 > 0) {
        // Negative number
        return pc - -%@intCast(u8, offset);
    } else {
        return pc + @truncate(u7, offset);
    };
}

fn handle(cpu: *Cpu, input: u8) Result {
    const out = 0; // some calculation
    return .{};
}

// TODO: Some general way to handle the 'carry' flag.
// TODO: Some general way to handle the 'overflow' flag (not just this inst.)
//       For now, crash on overflow.
//       Actually, the only instructions setting V are, ADC, SBC and BIT. Just
//       calc in those instrucitons...
//fn handleADC(cpu: *Cpu, arg: Arg) ?u8 {
//    cpu.regs.a += @intCast(u8, args.arg0.?) + @boolToInt(cpu.regs.c());
//    cpu.regs.prev = cpu.regs.a;
//}

fn handleAND(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a &= arg.u8;
    cpu.regs.prev = cpu.regs.a;
    return null;
}

// TODO: For all branches, set the proper cycle (+1 on succeed, +2 on new page)
fn handleBEQ(cpu: *Cpu, arg: Arg) ?u8 {
    if (cpu.regs.z()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleBMI(cpu: *Cpu, arg: Arg) ?u8 {
    if (cpu.regs.n()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleBNE(cpu: *Cpu, arg: Arg) ?u8 {
    if (!cpu.regs.z()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleBPL(cpu: *Cpu, arg: Arg) ?u8 {
    if (!cpu.regs.n()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleDLC(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.d = 0;
    return null;
}

fn handleCMP(cpu: *Cpu, arg: Arg) ?u8 {
    const val = cpu.regs.a -% arg.u8;
    cpu.regs.p.flag.c = val < 128;  // Y >= M
    cpu.regs.prev = val;
    return null;
}

fn handleCPX(cpu: *Cpu, arg: Arg) ?u8 {
    const val = cpu.regs.x -% arg.u8;
    cpu.regs.p.flag.c = val < 128;  // Y >= M
    cpu.regs.prev = val;
    return null;
}

fn handleCPY(cpu: *Cpu, arg: Arg) ?u8 {
    const val = cpu.regs.y -% arg.u8;
    cpu.regs.p.flag.c = val < 128;  // Y >= M
    cpu.regs.prev = val;
    return null;
}

fn handleDEC(cpu: *Cpu, arg: Arg) ?u8 {
    const val = arg.u8 -% 1;
    cpu.regs.prev = val;
    return val;
}

fn handleDEX(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.x -%= 1;
    cpu.regs.prev = cpu.regs.x;
    return null;
}

fn handleDEY(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.y -%= 1;
    cpu.regs.prev = cpu.regs.y;
    return null;
}

fn handleSEI(cpu: *Cpu, input: Arg) ?u8 {
    cpu.regs.p.flag.i = true;
    return null;
}

fn handleINC(cpu: *Cpu, arg: Arg) ?u8 {
    const val = arg.u8 +% 1;
    cpu.regs.prev = val;
    return val;
}

fn handleINX(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.x +%= 1;
    cpu.regs.prev = cpu.regs.x;
    return null;
}

fn handleINY(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.y +%= 1;
    cpu.regs.prev = cpu.regs.y;
    return null;
}

fn handleJMP(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.pc = arg.u16;

    // NOTE: "An original 6502 does not correctly fetch the target address if
    // the indirect vector valls on a page boundary"
    // http://obelisk.me.uk/6502/reference.html#JMP
    return null;
}

// TODO: Implement a proper stack... This is a mess...
fn handleJSR(cpu: *Cpu, arg: Arg) ?u8 {
    const pc = cpu.regs.pc - 1;
    const sp = @as(u16, 0x0100) | cpu.regs.sp;
    cpu.mmu.writeByte(sp, @truncate(u8, pc >> 8)) catch unreachable;
    cpu.regs.sp -= 1;
    cpu.mmu.writeByte(sp - 1, @truncate(u8, pc)) catch unreachable;
    cpu.regs.sp -= 1;
    cpu.regs.pc = arg.u16;
    return null;
}

fn handleLDA(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a = arg.u8;
    cpu.regs.prev = arg.u8;
    return null;
}

fn handleLDX(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.x = arg.u8;
    cpu.regs.prev = cpu.regs.x;
    return null;
}

fn handleLDY(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.y = arg.u8;
    cpu.regs.prev = cpu.regs.y;
    return null;
}

// TODO: This should not receive an arg, it does now.
fn handleRTS(cpu: *Cpu, arg: Arg) ?u8 {
    const sp = @as(u16, 0x0100) | cpu.regs.sp;
    var bytes: [2]u8 = undefined;
    cpu.mmu.readBytes(sp + 1, &bytes) catch unreachable;
    cpu.regs.sp += 2;
    cpu.regs.pc = (@as(u16, bytes[1]) << 8 | bytes[0]) + 1;
    return null;
}

fn handleSTA(cpu: *Cpu, arg: Arg) ?u8 {
    return cpu.regs.a;
}

fn handleSTX(cpu: *Cpu, arg: Arg) ?u8 {
    return cpu.regs.x;
}

fn handleSTY(cpu: *Cpu, arg: Arg) ?u8 {
    return cpu.regs.y;
}

fn handleCLD(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.d = false;
    return null;
}

fn handleTXS(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.sp = cpu.regs.x;
    return null;
}

fn handleTYA(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a = cpu.regs.y;
    cpu.regs.prev = cpu.regs.y;
    return null;
}
