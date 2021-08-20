const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const rom = @import("rom.zig");

const Cpu = struct {
    regs: struct {
        // General purpose
        a: u8,  // Accumulator
        x: u8,  // X index
        y: u8,  // Y index

        flag: u8,
        sp: u8,
        pc: u16,
    },

    // TODO: This is only implemented for the most basic rom right now.
    // RAM at $6000-$7FFF and ROM at $8000-$FFFF. ROM has to be 32KB
    map: struct {
        ram: []u8,
        rom: []u8,
    },

    // TODO: Idea for memory mapping:
    const MemoryMap = struct {
        // Maybe use pointers instead of slices, or maybe we can get rid of the
        // size entry (when using slices)
        const Map = struct {
            start: u16,
            size: u16,
            slice: []u8,
        };

        // Format I want for creating memory map:
        // MemoryMap.init(.{ 
        //      .{0x8000, 0x3fff, rom.prg_data},
        //      .{0x6000, 0x1fff, ram.data},
        // });
        fn init(maps: [_]Map) MemoryMap {

        }
    };

    pub fn init(rom: rom.Rom) !Cpu {

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

    const r = try rom.Rom.load(allocator, &file.reader());
    //print("{}\n", .{r});

    var tmp = try std.fs.cwd().createFile("prg_data.bin", .{ .truncate = true});
    defer tmp.close();
    print("{}\n", .{try tmp.write(r.prg_data)});
}
