const std = @import("std");
const mem = std.mem;
const log = std.log;
const assert = std.debug.assert;

const Cart = @This();

const CartridgeError = error {
};

const Mirroring = enum {
    horizontal,
    vertical,
    ignore,
};

const Header = struct {
    prg_size: u8,  // In units of 16KB
    chr_size: u8,  // In units of 8KB
    mapper: u8,

    mirroring: Mirroring,

    flags: packed struct {
        // Flags 6
        persistent_memory: bool,    // Cartridge contains persistent memory
        trainer: bool,              // 512-byte trainer at $7000-71FF

        // Flags 7
        vs_unisystem: bool,         // Can probably be ignored
        playchoice: bool,           // Not part of official spec, often ignored
        new_format: bool,           // Whether the rom uses NES 2.0
    },

    /// Parses the first 16 bytes of an iNES file.
    fn parse(bytes: []const u8) Header {
        assert(bytes.len >= 15);

        const header = Header {
            .prg_size = bytes[4],
            .chr_size = bytes[5],
            .mapper = bytes[7]&0xf0 | ((bytes[6]&0xf0) >> 4),

            .mirroring = blk: {
                if (bytes[6]&0x8 > 0) {
                    break :blk Mirroring.ignore;
                }
                switch (bytes[6] & 1) {
                    0 => break :blk Mirroring.horizontal,
                    1 => break :blk Mirroring.vertical,
                    else => unreachable,
                }
            },

            .flags = .{
                .persistent_memory = (bytes[6]&0x2) > 0,
                .trainer = (bytes[6]&0x4) > 0,

                .vs_unisystem = (bytes[7]&0x1) > 0,
                .playchoice = (bytes[7]&0x2) > 0,
                .new_format = (bytes[7]&0xc) == 0x8,
            },
        };

        if (header.flags.new_format) {
            log.warn(
                \\NES 2.0 Rom loaded; 
                \\NES 2.0 specific features are not yet implemented.
                , .{});
        }

        return header;
    }
};

allocator: *mem.Allocator,

mapper: u8,
mirroring: Mirroring,

trainer: ?[]u8 = null,
prg_data: []u8,
chr_data: []u8,

playchoice_inst: ?[]u8 = null,
playchoice_prom: ?[]u8 = null,


/// Parse raw bytes from `reader` into usable ROM data
pub fn init(allocator: *mem.Allocator, reader: anytype) !Cart {
    var cart: Cart = undefined;
    cart.allocator = allocator;

    // Parse header from ROM
    var buf: [16]u8 = undefined;
    const header_len = try reader.read(&buf);
    assert(header_len == buf.len);
    const header = Header.parse(&buf);

    // TODO: Handle trainer and playchoice
    assert(header.flags.trainer == false);
    assert(header.flags.playchoice == false);

    cart.mapper = header.mapper;
    cart.mirroring = header.mirroring;

    // Allocate memory for program data and read from ROM
    cart.prg_data = try allocator.alloc(u8, @as(u32, header.prg_size) * 0x4000);
    const prg_len = try reader.read(cart.prg_data);
    assert(prg_len == @as(u32, header.prg_size) * 0x4000);

    // Allocate memory for chr data and read from ROM
    cart.chr_data = try allocator.alloc(u8, @as(u32, header.chr_size) * 0x2000);
    const chr_len = try reader.read(cart.chr_data);
    assert(chr_len == @as(u32, header.chr_size) * 0x2000);

    log.info(
        \\Cartridge loaded:
        \\    prg size: {} ({}), chr size: {} ({})
        \\    mapper: {}
        , .{@as(u32, header.prg_size) * 0x4000, header.prg_size,
            @as(u32, header.chr_size) * 0x2000, header.chr_size,
            header.mapper});

    return cart;
}

pub fn deinit(self: Cart) void {
    self.allocator.free(self.prg_data);
    self.allocator.free(self.chr_data);
    if (self.trainer) |trainer| {
        self.allocator.free(trainer);
    }
}
