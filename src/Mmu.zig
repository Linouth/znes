const std = @import("std");

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
