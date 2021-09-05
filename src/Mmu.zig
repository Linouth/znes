const std = @import("std");
const mem = std.mem;
const log = std.log;
const sort = std.sort;
const math = std.math;

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
// NEXT:
// - Access control, having different banks / slices for read / write access
//   Probably best to implement a better data structure and have one for reads
//   and one for writes. Or multiple entries per address. ( Map{ ..., .ac = .rw} )
// - Callback / 'dirty-bit' set on reading/writing a specified address or region

const MmuError = error {
    /// Trying to access memory that has not been mapped.
    UnmappedMemory,

    /// Trying to map memory that has already been mapped.
    MemoryAlreadyMapped,

    /// The cartridges mapper is not supported.
    UnsupportedMapper,

    /// Trying to write to memory that does not have the writable flag set.
    WritingROMemory
};

const Map = struct {
    start: u16,
    end: u17,
    slice: []u8,

    writable: bool,

    fn startLessThan(ctx: void, lhs: Map, rhs: Map) bool {
        return lhs.start < rhs.start;
    }
};

allocator: *mem.Allocator,

// On setting up the MMU / Mapper, different memory maps are appended to this
// array. When that is finished, the array is sorted. On reading bytes, the
// start address of these maps is checked with a binary search.
// TODO: This can still be optimized greatly, preferably not having to search
// for the correct map and just use some lookup table.
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

// TODO: Temp public
pub fn sortMaps(self: *Mmu) void {
    sort.sort(Map, self.maps.items, {}, Map.startLessThan);
}

/// Binary search algo that checks if the needle falls in between `start` and
/// `end`.
fn searchMap(self: Mmu, addr: u16) ?Map {
    const items = self.maps.items;

    var left: usize = 0;
    var right: usize = items.len;

    var out: ?Map = null;

    while (left < right) {
        const mid = left + (right - left) / 2;

        if (addr == items[mid].start) {
            return items[mid];
        } else if (addr < items[mid].start) {
            right = mid;
        } else if (addr > items[mid].start) {
            left = mid + 1;
            out = items[mid];
        }
    }

    if (out) |map| {
        // Only return map if the requested addr actually falls in the found map
        if (addr < map.end) return map;
    }
    return null;
}

/// Check whether the provided range is free to map to or already has part of it
/// mapped. This function checks **each** item in order, from start to finish.
/// (So use it sparingly)
///
/// It could be nice to modify this function so that it can indicate which part
/// is already mapped and which part is free in a range.
fn rangeFree(self: Mmu, start: u32, end: u32) bool {
    for (self.maps.items) |map| {
        if ((start >= map.start and start < map.end)
            or (end > map.start and end <= map.end)) {
            return false;
        }
    }

    return true;
}

/// Map a slice to a specific range in virtual memory (excluding `end` itself)
// TODO: Temporarily public
pub fn mmap(self: *Mmu, map: Map) !void {
    assert(map.end > map.start);

    if (!self.rangeFree(map.start, map.end)) {
        return MmuError.MemoryAlreadyMapped;
    }

    const total_len = map.end - map.start;
    if (total_len > map.slice.len) {
        log.warn("The area to map ({}) is larger than the provided slice ({}), mirroring:",
            .{total_len, map.slice.len});
    }

    log.info("Mapping 0x{x} bytes to 0x{x}-0x{x}",
        .{total_len, map.start, map.end-1});

    try self.maps.append(map);
}

/// Return a single byte from (virtual) memory
pub fn readByte(self: Mmu, addr: u16) !u8 {
    if (self.searchMap(addr)) |map| {
        return map.slice[(addr - map.start) % map.slice.len];
    }

    return MmuError.UnmappedMemory;
}

pub fn readBytes(self: Mmu, addr: u16, buffer: []u8) !void {
    // TODO: This should be optimized. Not looking up each single byte. We could
    // assume the requested slice is inside one map. Then if it is not, look for
    // the corresponding map. If we do this, there needs to be some local buffer
    // to create a single slice from the multiple requested slices.

    for (buffer) |*byte, i| {
        byte.* = try self.readByte(addr + @intCast(u16, i));
    }
}

pub fn writeByte(self: *Mmu, addr: u16, byte: u8) !void {
    if (self.searchMap(addr)) |map| {
        if (!map.writable) return MmuError.WritingROMemory;
        map.slice[(addr - map.start) % map.slice.len] = byte;
        return;
    }

    return MmuError.UnmappedMemory;
}

/// Temporary mapper for the iNES 0 mapper
fn tmp_mapper_nrom(self: *Mmu, cart: Cart) !void {
    try self.mmap(.{.slice = cart.chr_data, .start = 0x6000, .end = 0x8000, .writable = false});
    try self.mmap(.{.slice = cart.prg_data, .start = 0x8000, .end = 0x10000, .writable = true});
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
    try mmu.mmap(.{.slice = &buf, .start = 0x100, .end = 0x110, .writable = false});
    try mmu.mmap(.{.slice = &buf, .start = 0x110, .end = 0x120, .writable = false});

    try expectError(MmuError.MemoryAlreadyMapped,
        mmu.mmap(.{.slice = &buf, .start = 0x110, .end = 0x130, .writable = false}));

    try expect((try mmu.readByte(0x110)) == 0x00);
    try expect((try mmu.readByte(0x11e)) == 0xee);

    // Mirroring
    try mmu.mmap(.{.slice = &buf, .start = 0x120, .end = 0x140, .writable = false});

    try expect((try mmu.readByte(0x13f)) == 0xff);
    try expect((try mmu.readByte(0x13c)) == 0xcc);
    try expect((try mmu.readByte(0x137)) == 0x77);
}
