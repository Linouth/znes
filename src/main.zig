const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const utils = @import("utils.zig");
const graphics = @import("ui.zig");
const op = @import("op.zig");

const Cart = @import("Cart.zig");
const Mmu = @import("Mmu.zig");
const Ppu = @import("Ppu.zig");
const Cpu = @import("Cpu.zig");
const Emu = @import("Emu.zig");

const c = graphics.c;

const FONT = "/usr/share/fonts/TTF/FiraCode-Regular.ttf";

pub fn main() anyerror!void {
    // Initialize UI related things, and open new window
    const ui = try graphics.UI.init(graphics.Frame.WIDTH, graphics.Frame.HEIGHT, FONT);

    // Define allocator used by the emulator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    // Handle program arguments
    var arg_it = std.process.args();
    log.info("Running: {s}", .{arg_it.next(allocator)});

    const rom_filename = try (arg_it.next(allocator) orelse {
        log.err("Expected first argument to hold the ROM filename", .{});
        return error.InvalidArgs;
    });

    var emu = try Emu.new(allocator).init(rom_filename);
    defer emu.deinit();

    const test_frame = emu.showTile(0, 0);

    var prev_time = c.SDL_GetTicks();

    // Main event loop
    outer: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) == 1) switch (event.type) {
            c.SDL_QUIT => break :outer,

            c.SDL_KEYDOWN => {
                const key = event.key.keysym.sym;
                switch (key) {
                    c.SDLK_q => break :outer,

                    c.SDLK_b => emu.debugging = true,
                    c.SDLK_c => {
                        print("Continuing\n", .{});
                        emu.running = true;
                        emu.debugging = false;
                    },
                    c.SDLK_n => emu.running = true,
                    c.SDLK_p => {
                        print("{any}\n", .{ emu.ppu.ports });
                        print("CPU Ticks: {}\n", .{ emu.cpu.ticks });
                        print("ppu addr: {*}\n", .{ &emu.ppu });
                    },
                    c.SDLK_t => utils.memDump(emu.ppu.vram[0..]),

                    else => log.info("Unhandled key: {s}", .{c.SDL_GetKeyName(key)}),
                }
            },

            else => {},
        };

        { // Emulation related calls
            if (emu.running) {
                switch (emu.cpu.regs.pc) {
                    //0xc28e, // Wait for vBlank to clear
                    0x0000
                        => emu.debugging = true,

                    else => {},
                }

                if (emu.debugging) {
                    emu.running = false;

                    emu.cpu.regs.print();

                    const opcode_now = try emu.mmu.readByte(emu.cpu.regs.pc);
                    const op0 = try op.decode(opcode_now);
                    print("This instruction: ${x:0>2}: {s}; {}, {}\n",
                        .{opcode_now, op0.mnemonic, op0.instruction_type, op0.addressing_mode});

                    const opcode_next = try emu.mmu.readByte(emu.cpu.regs.pc + op0.bytes);
                    const op1 = try op.decode(opcode_next);
                    print("Next instruction: ${x:0>2}: {s}; {}, {}\n",
                        .{opcode_next, op1.mnemonic, op1.instruction_type, op1.addressing_mode});
                }

                emu.cpu.tick() catch |err| {
                    switch (err) {
                        error.UnknownOpcode => {
                            log.err("Unknown opcode encountered: ${x:0>2}",
                                .{try emu.cpu.mmu.readByte(emu.cpu.regs.pc - 1)});
                        },

                        error.UnimplementedOperation => {
                            log.err("Unimplemented operation encountered: ${x:0>2}",
                                .{try emu.cpu.mmu.readByte(emu.cpu.regs.pc - 1)});
                        },

                        else => log.err("CPU ran into an unknown error: {}", .{err}),
                    }

                    emu.cpu.regs.print();
                    emu.debugging = true;
                };

                var ii: usize = 0;
                while (ii < 3) : (ii += 1) {
                    emu.ppu.tick();
                }
            }
        }

        // Rendering related calls
        if (prev_time < (@as(i64, c.SDL_GetTicks()) - 1000/60) ) {
            ui.setColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
            ui.renderClear();

            const r = c.SDL_Rect {
                .x = 0,
                .y = 0,
                .w = graphics.Frame.WIDTH,
                .h = graphics.Frame.HEIGHT,
            };
            try ui.renderFrame(&test_frame);

            //ui.renderText("This is a test string.", .{ .x = 0, .y = 0 }, null);

            ui.present();

            prev_time = c.SDL_GetTicks();
        }
    }

    //var buf: [0x210]u8 = undefined;
    //try emu.mmu.readBytes(0x0000, &buf);
    //utils.memDumpOffset(&buf, 0);
}
