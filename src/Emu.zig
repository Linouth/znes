const std = @import("std");
const print = std.debug.print;

const utils = @import("utils.zig");

const Cart = @import("Cart.zig");
const Mmu = @import("Mmu.zig");
const Ppu = @import("Ppu.zig");
const Cpu = @import("Cpu.zig");
const Emu = @This();

allocator: *std.mem.Allocator,

running: bool,
debugging: bool,

cart: Cart,
mmu: Mmu,
ppu: Ppu,
cpu: Cpu,

pub fn new(allocator: *std.mem.Allocator) Emu {
    return Emu {
        .allocator = allocator,
        .running = true,
        .debugging = false,

        .cart = undefined,
        .mmu = undefined,
        .ppu = undefined,
        .cpu = undefined,
    };
}

pub fn init(self: *Emu, rom_filename: []const u8) !*Emu {
    // Load ROM file
    var file = try std.fs.cwd().openFile(rom_filename, .{ .read = true });
    defer file.close();

    self.cart = try Cart.init(self.allocator, &file.reader());
    utils.memDumpOffset(self.cart.prg_data[0..], 0xC000);
    print("Mirroring: {}\n", .{self.cart.mirroring});

    self.mmu = try Mmu.init(self.allocator);
    try self.mmu.load(self.cart);

    self.cpu = try Cpu.init(&self.mmu);

    self.ppu = Ppu.init(&self.cpu.nmi);

    // TODO: Temporary. THE RAM IS NEVER FREED!
    var ram = try self.allocator.alloc(u8, 0x800);
    try self.mmu.mmap(.{ .slice = ram, .start = 0x0000, .end = 0x2000, .writable = true });
    try self.mmu.mmap(.{
        .slice = @ptrCast([*]u8, &self.ppu.ports)[0..8],
        .start = 0x2000,
        .end = 0x4000,
        .writable = true,
        .callback = blk: {
            // NOTE: For some reason .ctx and .func are null if I init Callback
            // without first saving it to a variable.
            const cb = Mmu.Callback {
                .ctx = &self.ppu,
                .func = Ppu.memoryCallback,
            };
            break :blk cb;
        },
    });
    var apu_io_regs: [0x18]u8 = .{0} ** 0x18;  // This variable is dropped out of scope at return.
    try self.mmu.mmap(.{ .slice = &apu_io_regs, .start = 0x4000, .end = 0x4018, .writable = true });

    self.mmu.sortMaps();
    return self;
}

pub fn deinit(self: *Emu) void {
    defer self.cart.deinit();
    defer self.mmu.deinit();
}
