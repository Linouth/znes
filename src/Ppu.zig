const std = @import("std");
const print = std.debug.print;

const Ppu = @This();


// The PPU has an internal data bus to the CPU. 

const Ports = packed struct {
    ppuctrl: u8,
    ppumask: u8,
    ppustatus: u8,
    oamaddr: u8,
    oamdata: u8,
    ppuscroll: u8,
    ppuaddr: u8,
    ppudata: u8,
    oamdma: u8,
};

ports: Ports,

pub fn init() Ppu {
    return Ppu{
        .ports = .{
            .ppuctrl = 0,
            .ppumask = 0,
            .ppustatus = 0b10100000,
            .oamaddr = 0,
            .oamdata = 0,
            .ppuscroll = 0,
            .ppuaddr = 0,
            .ppudata = 0,
            .oamdma = 0,
        },
    };
}

pub fn reset(self: *Ppu) void {
    self.ports.ppuctrl = 0;
    self.ports.ppumask = 0;
    self.ports.ppustatus = 0b10100000;
    self.ports.ppuscroll = 0;
    self.ports.ppudata = 0;
}

// TODO: Try to implement some callback/hook on mem read/write instead of polling
pub fn tick(self: *Ppu) void {
    const state = struct {
        var prev_ports: Ports = .{
            .ppuctrl = 0,
            .ppumask = 0,
            .ppustatus = 0b10100000,
            .oamaddr = 0,
            .oamdata = 0,
            .ppuscroll = 0,
            .ppuaddr = 0,
            .ppudata = 0,
            .oamdma = 0,
        };
    };

    const ports = @ptrCast(*[9]u8, &self.ports);
    const prev_ports = @ptrCast(*[9]u8, &state.prev_ports);

    if (!std.mem.eql(u8, prev_ports, ports)) {
        print("PPU State changed!\n", .{});
        state.prev_ports = self.ports;

        @panic("");
    }
}
