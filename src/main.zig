const std = @import("std");
const print = std.debug.print;
const log = std.log;

const Mirroring = enum {
    ignore,
    horizontal,
    vertical,
};

const TvStandard = enum {
    ntsc,
    pal,
};

const Header = struct {
    prg_size: u8,  // 16KB units
    chr_size: u8,  // 8KB units

    mapper: u8,

    mirroring: Mirroring,

    flags: packed struct {
        // Flags 6
        persistent_memory: bool,    // Cartridge contains persistent memory
        trainer: bool,              // 512-byte trainer at $7000-71FF

        // Flags 7
        vs_unisystem: bool,
        playchoice_10: bool,        // Not part of official spec, often ignored
        new_format: bool,           // Whether the rom uses NES 2.0
    },

    tv_standard: TvStandard,        // Often ignored. NES Roms barely use this bit

};

const Rom = struct {
    header: Header = undefined,

    pub fn load(reader: *std.fs.File.Reader) !Rom {

        return Rom {
            //.header = Header {

            //},
        };
    }
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var arg_it = std.process.args();

    log.info("Running: {s}", .{arg_it.next(allocator)});

    const rom_filename = try (arg_it.next(allocator) orelse {
        log.warn("Expected first argument to hold the ROM filename", .{});
        return error.InvalidArgs;
    });

    var file = try std.fs.cwd().openFile(rom_filename, .{ .read = true });
    defer file.close();

    const rom = try Rom.load(&file.reader());
    print("{}\n", rom);
}
