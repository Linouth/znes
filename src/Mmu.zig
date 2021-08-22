const std = @import("std");
const mem = std.mem;
const log = std.log;

const ArrayList = std.ArrayList;

const assert = std.debug.assert;
const print = std.debug.print;

const Cart = @import("Cart.zig");
const Mmu = @This();

// As of now only implements the 0 iNES mapper (The simplest one).
// https://wiki.nesdev.com/w/index.php?title=NROM
// Banks are fixed;
//     CPU $6000-$7FFF; PRG RAM
//     CPU $8000-$BFFF; First 16KB of ROM
//     CPU $C000-$FFFF; Last 16KB or ROM, or mirror of $8000-$BFFF

// What we need:
// - Support for mirroring to fill a specific bank if the buffer is not large
//   enough. When reading single bytes this is easy, however if I want to read
//   multiple and return a slice containing the n bytes requtested this becomes
//   more complex at the boundary of the mirror. Maybe this can be done with a
//   custom Reader that has an internal buffer where the data mirrored data is
//   stored at the boundaries for these cases.
// - Later, be able to switch between buffers during runtime. So, having
//   multiple banks available and changing the two main slices (8000-bfff and
//   c000-ffff) to another of these banks.

const MmuError = error {
    /// Trying to access memory that has not been mapped.
    UnmappedMemory,

    /// Trying to map memory that has already been mapped.
    MemoryAlreadyMapped,

    /// The cartridges mapper is not supported.
    UnsupportedMapper,
};

const Map = struct {
    start: u16,
    slice: []u8,
};

allocator: *mem.Allocator,

// TODO: Add some trie so that we don't have to loop over every mapping on every
// single byte read.
maps: ArrayList(Map),

pub fn init(allocator: *mem.Allocator) !Mmu {
    return Mmu {
        .allocator = allocator,
        .maps = ArrayList(Map).init(allocator),
    };
}

pub fn deinit(self: *Mmu) void {
    defer self.maps.deinit();
}

/// Load a cartridge into (virtual) memory using the required mapper.
pub fn load(self: *Mmu, cart: Cart) !void {
    // Currently only the 0 mapper is being implemented
    if (cart.mapper != 0) return MmuError.UnsupportedMapper;

    // TODO: Enum for the different mappers
    switch (cart.mapper) {
        0 => try self.tmp_mapper_nrom(cart),
        else => unreachable,
    }
}

/// Return a single byte from (virtual) memory
pub fn getByte(self: Mmu, addr: u16) !u8 {
    for (self.maps.items) |map| {
        const map_end = map.start + map.slice.len;

        if (addr >= map.start and addr < map_end) {
            return map.slice[addr - map.start];
        }
    }

    return MmuError.UnmappedMemory;
}

pub fn getBytes(self: Mmu, addr: u16, buffer: []u8) !void {
    // TODO: This REALLY needs to be optimized.

    for (buffer) |*byte, i| {
        byte.* = try self.getByte(addr + @intCast(u16, i));
    }
}

/// Check whether the provided range is free to map to or already has part of it
/// mapped.
///
/// It could be nice to modify this function so that it can indicate which part
/// is already mapped and which part is free in a range.
fn rangeFree(self: Mmu, start: u32, end: u32) bool {
    for (self.maps.items) |map| {
        const map_end = map.start + map.slice.len;

        if ((start >= map.start and start < map_end)
            or (end > map.start and end <= map_end)) {
            return false;
        }
    }

    return true;
}

/// Map a slice to a specific range in virtual memory (excluding `end` itself)
fn mmap(self: *Mmu, slice: []u8, start: u16, end: u17) !void {
    assert(end > start);

    if (!self.rangeFree(start, end)) {
        return MmuError.MemoryAlreadyMapped;
    }

    const total_len = end - start;
    if (total_len > slice.len) {
        log.warn("The area to map ({}) is larger than the provided slice ({}), mirroring:",
            .{total_len, slice.len});
    }

    log.info("Mapping 0x{x} bytes to 0x{x}-0x{x}",
        .{total_len, start, end-1});

    var addr: u17 = start;
    var len: u17 = 0;
    while (addr < end) : (addr += len) {
        len = std.math.min(end - addr, slice.len);

        const map = Map {
            .start = @truncate(u16, addr),
            .slice = slice[0..len]
        };

        try self.maps.append(map);
    }
}

/// Temporary mapper for the iNES 0 mapper
fn tmp_mapper_nrom(self: *Mmu, cart: Cart) !void {
    try self.mmap(cart.chr_data, 0x6000, 0x8000);
    try self.mmap(cart.prg_data, 0x8000, 0x10000);
}


const testing = std.testing;
const expect = testing.expect;
const expectError = testing.expectError;

test "Mmu mapping virtual memory/mirroring" {
    var mmu = try Mmu.init(testing.allocator);
    defer mmu.deinit();

    var buf: [16]u8 = .{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};

    // Regular mapping
    try mmu.mmap(&buf, 0x100, 0x110);
    try mmu.mmap(&buf, 0x110, 0x120);

    try expectError(MmuError.MemoryAlreadyMapped,
        mmu.mmap(&buf, 0x110, 0x130));

    try expect(mmu.getByte(0x110).? == 0x00);
    try expect(mmu.getByte(0x11e).? == 0xee);

    // Mirroring
    try mmu.mmap(&buf, 0x120, 0x140);

    try expect(mmu.getByte(0x13f).? == 0xff);
    try expect(mmu.getByte(0x13c).? == 0xcc);
    try expect(mmu.getByte(0x137).? == 0x77);
}
