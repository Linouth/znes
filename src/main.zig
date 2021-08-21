const std = @import("std");
const mem = std.mem;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

const Cart = @import("Cart.zig");

fn memDump(chunk: []const u8) void {
    memDumpOffset(chunk, 0);
}

fn memDumpOffset(chunk: []const u8, offset: u32) void {
    const stdout = std.io.getStdOut().writer();

    var index: usize = 0;
    while (index < chunk.len) : (index += 1) {
        if (index % 16 == 0) {
            _ = stdout.write("\n") catch {};
            stdout.print("{x:0>8}  ", .{index + offset}) catch {};
        } else if (index % 8 == 0) {
            _ = stdout.write(" ") catch {};
        }

        stdout.print("{x:0>2} ", .{chunk[index]}) catch {};
    }
    _ = stdout.write("\n") catch {};
}

const Cpu = struct {
    const MemoryMap = struct {
        const MemoryError = error {
            /// Trying to access memory that has not been mapped.
            UnmappedMemory,

            /// Trying to map memory that has already been mapped.
            MemoryAlreadyMapped,
        };

        // The length of the map is implicitly stored in the slice (slice.len)
        const Map = struct {
            start: u16,
            slice: []u8,
        };

        // TODO: Remove this hard-coded map count limit
        maps: [32]?Map = .{null} ** 32,

        /// Initialize the memory map. `maps` argument is an array with Map
        /// items.
        ///
        /// Format I want for creating memory map:
        /// MemoryMap.init(.{ 
        ///      .{ .start = 0x8000, .slice = rom.prg_data},
        ///      .{ .start = 0x6000, .slice = ram.data},
        /// });
        fn init(maps: anytype) MemoryError!MemoryMap {
            var mmap = MemoryMap{};
            for (maps) |map, i| {
                // TODO: Temporary check. Implement a smarter data structure for
                // this mapping (some trie?)
                assert(i < 32);

                // TODO: Again, since the data structure for the maps is a
                // simple array, it has to check every single entry for every
                // map being added. This can be faster with a proper data
                // structure.
                if (mmap.get(map.start, map.slice.len)) |_| {
                    return MemoryError.MemoryAlreadyMapped;
                } else |_| { }  // We expect an error here. Error is good.

                log.info("Mapping 0x{x} bytes, starting at 0x{x}",
                    .{map.slice.len, map.start});

                mmap.maps[i] = map;
            }

            return mmap;
        }

        fn get(self: MemoryMap, addr: u16, len: usize) MemoryError![]u8 {

            var i: u16 = 0;
            while (self.maps[i]) |map| : (i += 1) {
                if ((addr >= map.start) and (addr < (map.start + map.slice.len))) {
                    const index = addr - map.slice.len;
                    return map.slice[index..index+len];
                }
            }

            return MemoryError.UnmappedMemory;
        }
    };

    regs: struct {
        // General purpose
        a: u8,  // Accumulator
        x: u8,  // X index
        y: u8,  // Y index

        flag: u8,
        sp: u8,
        pc: u16,
    } = undefined,

    // TODO: This is only implemented for the most basic rom right now.
    // RAM at $6000-$7FFF and ROM at $8000-$FFFF. ROM has to be 32KB
    map: MemoryMap,

    pub fn init(r: Cart) !Cpu {

        var cpu = Cpu {
            .map = try MemoryMap.init([_]MemoryMap.Map{
                .{.start = 0x6000, .slice = r.chr_data},
                .{.start = 0x8000, .slice = r.prg_data},
            }),
        };

        cpu.reset();

        return cpu;
    }

    fn reset(self: *Cpu) void {
        const pc_bytes = self.map.get(0xfffc, 2) catch unreachable;

        self.regs = .{
            .a = 0,
            .x = 0,
            .y = 0,

            .flag = 0,
            .sp = 0,
            .pc = @as(u16, pc_bytes[1]) << 8 | pc_bytes[0],
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

    const r = try Cart.init(allocator, &file.reader());
    //print("{any}\n", .{r.header});

    const end = r.prg_data.len;
    print("{}\n", .{end});
    memDumpOffset(r.prg_data[0..], 0xC000);

    //var cpu = Cpu.init(r);
}
