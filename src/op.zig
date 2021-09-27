const std = @import("std");

const print = std.debug.print;
const utils = @import("utils.zig");

const Cpu = @import("Cpu.zig");


const OperationError = error {
    /// This operation is known but has not yet been implemented.
    UnimplementedOperation,

    /// Tried to handle an unknown opcode.
    UnknownOpcode,

    /// Trying to write to memory, but address is set to null.
    NullAddress,
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

            const addr: ?u16 = switch (self.addressing_mode) {
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

                else => null,
            };

            var arg: Arg = if (self.instruction_type == .memory_read) switch (self.addressing_mode) {
                .implied => Arg{ .none = {} },
                .accumulator => Arg{ .u8 = cpu.regs.a },
                .immediate, .relative => Arg{ .u8 = bytes[0] },

                else => Arg{ .u8 = try cpu.mmu.readByte(addr.?) },
            } else if (self.instruction_type == .jump) switch (self.addressing_mode) {
                .relative => Arg{ .u8 = bytes[0] },
                .absolute => Arg{ .u16 = addr.? },  // Tricky for combination, in mem read read this addr; in jump this is the arg. Rest is easy
                .indirect => Arg{ .u8 = try cpu.mmu.readByte(addr.?) },

                .implied => Arg{ .none = {} },

                else => unreachable,
            } else Arg{ .none = {} };

            stdout.print("Bytes: 0x{x:0>2} 0x{x:0>2}\n", .{bytes[0], bytes[1]}) catch unreachable;
            stdout.print("Arg: {}\n", .{arg}) catch unreachable;

            const result = handler(cpu, arg);

            if (result) |res| {
                if (self.addressing_mode == .accumulator) {
                    // For some rare instructions that can store to either the
                    // accumulator or memory.
                    stdout.print("Writing 0x{x:0>2} to accumulator\n", .{res}) catch unreachable;
                    cpu.regs.a = res;
                } else {
                    if (addr) |addrx| {
                        stdout.print("Writing 0x{x:0>2} to address 0x{x:0>4}\n", .{res, addrx}) catch unreachable;
                        try cpu.mmu.writeByte(addrx, res);
                    } else {
                        return OperationError.NullAddress;
                    }
                }
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

        // Arithmetic Shift Left
        .{ .mnemonic = "ASL", .instruction_type = .memory_read, .opcodes = .{
            .{0x0A, .{ .addressing_mode = .accumulator,         .bytes = 1, .cycles = 2 }},
            .{0x06, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 5 }},
            .{0x16, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 6 }},
            .{0x0E, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
            .{0x1E, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 7 }},
        }},

        // Branch if Carry Clear
        .{ .mnemonic = "BCC", .instruction_type = .jump, .opcodes = .{
            .{0x90, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Branch if Carry Set
        .{ .mnemonic = "BCS", .instruction_type = .jump, .opcodes = .{
            .{0xB0, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Branch if Equal
        .{ .mnemonic = "BEQ", .instruction_type = .jump, .opcodes = .{
            .{0xF0, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Bit Test
        .{ .mnemonic = "BIT", .instruction_type = .memory_read, .opcodes = .{
            .{0x24, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x2C, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
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

        //BRK

        // Branch if Overflow Clear
        .{ .mnemonic = "BVC", .instruction_type = .jump, .opcodes = .{
            .{0x50, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Branch if Overflow Set
        .{ .mnemonic = "BVS", .instruction_type = .jump, .opcodes = .{
            .{0x70, .{ .addressing_mode = .relative,            .bytes = 2, .cycles = 2 }},
        }},

        // Clear Carry Flag
        .{ .mnemonic = "CLC", .instruction_type = .flags_set, .opcodes = .{
            .{0x18, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Clear Decimal Mode
        .{ .mnemonic = "CLD", .instruction_type = .flags_set, .opcodes = .{
            .{0xD8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Clear Interrupt Disable
        .{ .mnemonic = "CLI", .instruction_type = .flags_set, .opcodes = .{
            .{0x58, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Clear Overflow Flag
        .{ .mnemonic = "CLV", .instruction_type = .flags_set, .opcodes = .{
            .{0xB8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
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

        // Exclusive OR
        .{ .mnemonic = "EOR", .instruction_type = .memory_read, .opcodes = .{
            .{0x49, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0x45, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x55, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x4D, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0x5D, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0x59, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0x41, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0x51, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Increment Memory
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
            .{0xA6, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xB6, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0xAE, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0xBE, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
        }},

        // Load Y Register
        .{ .mnemonic = "LDY", .instruction_type = .memory_read, .opcodes = .{
            .{0xA0, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xA4, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xB4, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0xAC, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0xBC, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
        }},

        // Logical Shift Right
        .{ .mnemonic = "LSR", .instruction_type = .memory_read, .opcodes = .{
            .{0x4A, .{ .addressing_mode = .accumulator,         .bytes = 1, .cycles = 2 }},
            .{0x46, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 5 }},
            .{0x56, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 6 }},
            .{0x4E, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
            .{0x5E, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 7 }},
        }},
        //NOP

        // Logical Inclusive OR
        .{ .mnemonic = "ORA", .instruction_type = .memory_read, .opcodes = .{
            .{0x09, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0x05, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0x15, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0x0D, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0x1D, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0x19, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0x01, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0x11, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Push Accumulator
        .{ .mnemonic = "PHA", .instruction_type = .memory_write, .opcodes = .{
            .{0x48, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 3 }},
        }},

        // Push Processor Status
        .{ .mnemonic = "PHP", .instruction_type = .memory_write, .opcodes = .{
            .{0x08, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 3 }},
        }},

        // Pull Accumulator
        .{ .mnemonic = "PLA", .instruction_type = .memory_read, .opcodes = .{
            .{0x68, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 4 }},
        }},

        // Pull Processor Status
        .{ .mnemonic = "PLP", .instruction_type = .memory_read, .opcodes = .{
            .{0x28, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 4 }},
        }},

        // Rotate Left
        .{ .mnemonic = "ROL", .instruction_type = .memory_read, .opcodes = .{
            .{0x2A, .{ .addressing_mode = .accumulator,         .bytes = 1, .cycles = 2 }},
            .{0x26, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 5 }},
            .{0x36, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 6 }},
            .{0x2E, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
            .{0x3E, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 7 }},
        }},

        // Rotate Left
        .{ .mnemonic = "ROR", .instruction_type = .memory_read, .opcodes = .{
            .{0x6A, .{ .addressing_mode = .accumulator,         .bytes = 1, .cycles = 2 }},
            .{0x66, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 5 }},
            .{0x76, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 6 }},
            .{0x6E, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 6 }},
            .{0x7E, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 7 }},
        }},

        // Return from Interrupt
        .{ .mnemonic = "RTI", .instruction_type = .jump, .opcodes = .{
            .{0x40, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 6 }},
        }},

        // Return from Subroutine
        .{ .mnemonic = "RTS", .instruction_type = .jump, .opcodes = .{
            .{0x60, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 6 }},
        }},

        // Subtract with Carry (with Borrow)
        .{ .mnemonic = "SBC", .instruction_type = .memory_read, .opcodes = .{
            .{0xE9, .{ .addressing_mode = .immediate,           .bytes = 2, .cycles = 2 }},
            .{0xE5, .{ .addressing_mode = .zero_page,           .bytes = 2, .cycles = 3 }},
            .{0xF5, .{ .addressing_mode = .zero_page_x,         .bytes = 2, .cycles = 4 }},
            .{0xED, .{ .addressing_mode = .absolute,            .bytes = 3, .cycles = 4 }},
            .{0xFD, .{ .addressing_mode = .absolute_x,          .bytes = 3, .cycles = 4 }},
            .{0xF9, .{ .addressing_mode = .absolute_y,          .bytes = 3, .cycles = 4 }},
            .{0xE1, .{ .addressing_mode = .indexed_indirect,    .bytes = 2, .cycles = 6 }},
            .{0xF1, .{ .addressing_mode = .indirect_indexed,    .bytes = 2, .cycles = 5 }},
        }},

        // Set Carry Flag
        .{ .mnemonic = "SEC", .instruction_type = .flags_set, .opcodes = .{
            .{0x38, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Set Decimal Flag
        .{ .mnemonic = "SED", .instruction_type = .flags_set, .opcodes = .{
            .{0xF8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Set Interrupt Disable
        .{ .mnemonic = "SEI", .instruction_type = .flags_set, .opcodes = .{
            .{0x78, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
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

        // Transfer Accumulator to X
        .{ .mnemonic = "TAX", .instruction_type = .register_modify, .opcodes = .{
            .{0xAA, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Transfer Accumulator to Y
        .{ .mnemonic = "TAY", .instruction_type = .register_modify, .opcodes = .{
            .{0xA8, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Transfer Stack Pointer to X
        .{ .mnemonic = "TSX", .instruction_type = .register_modify, .opcodes = .{
            .{0xBA, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
        }},

        // Transfer X to Accumulator
        .{ .mnemonic = "TXA", .instruction_type = .register_modify, .opcodes = .{
            .{0x8A, .{ .addressing_mode = .implied,             .bytes = 1, .cycles = 2 }},
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

inline fn bit(dat: u16, b: u4) bool {
    return (dat & (@as(u16, 1) << b)) > 0;
}

// --- Handlers ---

fn handleADC(cpu: *Cpu, arg: Arg) ?u8 {
    const res: u12 = cpu.regs.a + arg.u8 + @boolToInt(cpu.regs.c());

    // TODO: Some better way to set the oVerflow bit
    const pos = (cpu.regs.a + arg.u8) >= 0;
    const neg_bit = bit(res, 7);
    if ((pos and neg_bit) or (!pos and !neg_bit)) {
        cpu.regs.p.flag.v = true;
    } else {
        cpu.regs.p.flag.v = false;
    }

    cpu.regs.p.flag.c = (res & 0xf00) > 0;
    cpu.regs.a = @truncate(u8, res);
    cpu.regs.prev = cpu.regs.a;

    return null;
}

fn handleAND(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a &= arg.u8;
    cpu.regs.prev = cpu.regs.a;
    return null;
}

fn handleASL(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.c = arg.u8 & 0x80 > 0;
    return arg.u8 *% 2;
}

// TODO: For all branches, set the proper cycle (+1 on succeed, +2 on new page)
fn handleBCC(cpu: *Cpu, arg: Arg) ?u8 {
    if (!cpu.regs.c()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleBCS(cpu: *Cpu, arg: Arg) ?u8 {
    if (cpu.regs.c()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleBEQ(cpu: *Cpu, arg: Arg) ?u8 {
    if (cpu.regs.z()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

// TODO: Small problem; the current way of handling the n flag does not allow
// for us to set it manually here. It is derived from regs.prev, but that should
// be set to A & M for the zero flag.
//fn handleBIT(cpu: *Cpu, arg: Arg) ?u8 {
//    
//}

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

fn handleBVC(cpu: *Cpu, arg: Arg) ?u8 {
    if (!cpu.regs.v()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleBVS(cpu: *Cpu, arg: Arg) ?u8 {
    if (cpu.regs.v()) {
        cpu.regs.pc = calcBranchOffset(cpu.regs.pc, arg.u8);
    }
    return null;
}

fn handleCLC(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.c = false;
    return null;
}

fn handleCLD(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.d = false;
    return null;
}

fn handleCLI(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.i = false;
    return null;
}

fn handleCLV(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.v = false;
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

fn handleEOR(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a ^= arg.u8;
    cpu.regs.prev = cpu.regs.a;
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

fn handleJSR(cpu: *Cpu, arg: Arg) ?u8 {
    const pc = cpu.regs.pc - 1;
    cpu.push(@truncate(u8, pc >> 8));
    cpu.push(@truncate(u8, pc));

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

fn handleLSR(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.flag.c = arg.u8 & 1 > 0;
    const res = arg.u8 / 2;
    cpu.regs.prev = res;
    return res;
}

fn handleORA(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a = cpu.regs.a | arg.u8;
    cpu.regs.prev = cpu.regs.a;
    return null;
}

fn handlePHA(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.push(cpu.regs.a);
    return null;
}

fn handlePHP(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.push(cpu.regs.p.raw);
    return null;
}

fn handlePLA(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a = cpu.pop();
    cpu.regs.prev = cpu.regs.a;
    return null;
}

fn handlePLP(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.p.raw = cpu.pop();
    return null;
}

fn handleROL(cpu: *Cpu, arg: Arg) ?u8 {
    const c = cpu.regs.c();
    cpu.regs.p.flag.c = (arg.u8 & 0x80) > 0;

    const res = (arg.u8 << 1) | @boolToInt(c);
    cpu.regs.prev = res;
    return res;
}

fn handleROR(cpu: *Cpu, arg: Arg) ?u8 {
    const c = cpu.regs.c();
    cpu.regs.p.flag.c = (arg.u8 & 0x01) > 0;

    const res = (arg.u8 >> 1) | (@as(u8, @boolToInt(c)) << 7);
    cpu.regs.prev = res;
    return res;
}

fn handleRTI(cpu: *Cpu, arg: Arg) ?u8 {
    // Pull status register from the stack (ignoring the Break flag)
    cpu.regs.p.raw = cpu.pop() & (~@as(u8, 0b00010000));

    const bytes: [2]u8 = .{ cpu.pop(), cpu.pop() };
    cpu.regs.pc = @as(u16, bytes[1]) << 8 | bytes[0];

    return null;
}

// TODO: This should not receive an arg, it does now.
fn handleRTS(cpu: *Cpu, arg: Arg) ?u8 {
    const bytes: [2]u8 = .{ cpu.pop(), cpu.pop() };
    cpu.regs.pc = (@as(u16, bytes[1]) << 8 | bytes[0]) + 1;

    return null;
}

// TODO: Try to use the same 'circuit' for both ADC and SBC
fn handleSBC(cpu: *Cpu, arg: Arg) ?u8 {
    const res: u8 = cpu.regs.a -% arg.u8 -% @boolToInt(!cpu.regs.c());

    if (res > cpu.regs.a) {
        // Overflow occured
        cpu.regs.p.flag.c = false;
    }

    if ((cpu.regs.a & 0x80 > 0) and (res & 0x80 == 0)) {
        // Going from negative to positive with a subtract is invalid
        cpu.regs.p.flag.v = true;
    }

    cpu.regs.a = res;
    cpu.regs.prev = cpu.regs.a;

    return null;
}

fn handleSEC(cpu: *Cpu, input: Arg) ?u8 {
    cpu.regs.p.flag.c = true;
    return null;
}

fn handleSED(cpu: *Cpu, input: Arg) ?u8 {
    cpu.regs.p.flag.i = true;
    return null;
}

fn handleSEI(cpu: *Cpu, input: Arg) ?u8 {
    cpu.regs.p.flag.i = true;
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

fn handleTAX(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.x = cpu.regs.a;
    cpu.regs.prev = cpu.regs.x;
    return null;
}

fn handleTAY(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.y = cpu.regs.a;
    cpu.regs.prev = cpu.regs.y;
    return null;
}

fn handleTSX(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.x = cpu.regs.sp;
    cpu.regs.prev = cpu.regs.sp;
    return null;
}

fn handleTXA(cpu: *Cpu, arg: Arg) ?u8 {
    cpu.regs.a = cpu.regs.x;
    cpu.regs.prev = cpu.regs.x;
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
