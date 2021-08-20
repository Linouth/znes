const std = @import("std");
const mem = std.mem;
const log = std.log;
const assert = std.debug.assert;


pub const Rom = struct {
    const RomError = error {
        headerTooSmall,
    };

    const Header = struct {

        const Mirroring = enum {
            horizontal,
            vertical,
            ignore,
        };

        prg_size: u32,
        chr_size: u32,
        mapper: u8,

        mirroring: Mirroring,

        flags: packed struct {
            // Flags 6
            persistent_memory: bool,    // Cartridge contains persistent memory
            trainer: bool,              // 512-byte trainer at $7000-71FF

            // Flags 7
            vs_unisystem: bool,         // Can probably be ignored
            playchoice_10: bool,        // Not part of official spec, often ignored
            new_format: bool,           // Whether the rom uses NES 2.0
        },

        // Parses the first 16 bytes of an iNES file.
        pub fn parse(bytes: []const u8) Header {
            assert(bytes.len >= 15);

            const header = Header {
                .prg_size = bytes[4] * @as(u32, 2) << (14-1),
                //.prg_size = bytes[4] * 2<<(14-1),
                .chr_size = bytes[5] * @as(u32, 2) << (13-1),
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
                    .playchoice_10 = (bytes[7]&0x2) > 0,
                    .new_format = (bytes[7]&0xc) == 0x8,
                },
            };

            if (header.flags.new_format) {
                log.info(
                    \\NES 2.0 Rom loaded; 
                    \\NES 2.0 specific features are not yet implemented."
                    , .{});
            }

            return header;
        }
    };

    header: Header,

    trainer: ?[]u8 = null,
    prg_data: []u8,
    chr_data: []u8,

    playchoice_inst: ?[]u8 = null,
    playchoice_prom: ?[]u8 = null,


    /// Parse raw bytes from `reader` into usable ROM data
    pub fn load(allocator: *mem.Allocator, reader: anytype) !Rom {
        var rom: Rom = undefined;

        // Parse header from rom
        var buf: [16]u8 = undefined;
        const header_len = try reader.read(&buf);
        rom.header = Header.parse(&buf);
        assert(header_len == buf.len);

        // TODO: Handle trainer and playchoice

        // Allocate memory for program data and read from ROM
        rom.prg_data = try allocator.alloc(u8, rom.header.prg_size);
        const prg_len = try reader.read(rom.prg_data);
        assert(prg_len == rom.header.prg_size);

        // Allocate memory for chr data and read from ROM
        rom.chr_data = try allocator.alloc(u8, rom.header.chr_size);
        const chr_len = try reader.read(rom.chr_data);
        assert(chr_len == rom.header.chr_size);

        return rom;
    }
};
