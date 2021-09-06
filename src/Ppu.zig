const std = @import("std");
const print = std.debug.print;
const log = std.log;

const Map = @import("Mmu.zig").Map;
const Ppu = @This();


const Sprite = packed struct {
    pos_y: u8,
    index: u8,
    attributes: packed struct {
        palette: u2,
        _: u3,
        prio: bool,
        flip_h: bool,
        flip_v: bool,
    },
    pos_x: u8,
};

// The PPU has an internal data bus to the CPU. 
const Ports = packed struct {
    ppuctrl: u8 = 0,
    ppumask: u8 = 0,
    ppustatus: packed struct {
        _: u5 = undefined,
        sprite_overflow: bool = true,
        sprite_0_hit: bool = false,
        vblank: bool = true,
    } = .{},
    oamaddr: u8 = 0,
    oamdata: u8 = undefined,
    ppuscroll: u8 = 0,
    ppuaddr: u8 = 0,
    ppudata: u8 = 0,
    oamdma: u8 = undefined,

    const PortNames = enum(u16) {
        ppu_ctrl = 0x2000,
        ppu_mask,
        ppu_status,
        oam_addr,
        oam_data,
        ppu_scroll,
        ppu_addr,
        ppu_data,
        oam_dma = 0x4014,
    };
};

ports: Ports,

vblank_clear: bool = false,

pub fn init() Ppu {
    return Ppu{
        .ports = .{},
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
    //const state = struct {
    //    var prev_ports: Ports = .{
    //        .ppuctrl = 0,
    //        .ppumask = 0,
    //        .ppustatus = 0b10100000,
    //        .oamaddr = 0,
    //        .oamdata = 0,
    //        .ppuscroll = 0,
    //        .ppuaddr = 0,
    //        .ppudata = 0,
    //        .oamdma = 0,
    //    };
    //};

    //const ports = @ptrCast(*[9]u8, &self.ports);
    //const prev_ports = @ptrCast(*[9]u8, &state.prev_ports);

    //if (!std.mem.eql(u8, prev_ports, ports)) {
    //    print("PPU State changed!\n", .{});
    //    state.prev_ports = self.ports;

    //    @panic("");
    //}

    if (self.vblank_clear) {
        print("vBlankClear SET!\n", .{});
        self.ports.ppustatus.vblank = false;
        self.vblank_clear = false;
    }
}

pub fn memoryCallback(ctx: *c_void, map: Map, addr: u16, data: ?u8) void {
    const self: *Ppu = @ptrCast(*Ppu, ctx);
    print("Inside CB {}\n", .{self});

    //print("PPU Memory access; ", .{});
    //if (data) |dat| {
    //    print("write {x:0>2};\t", .{dat});
    //} else {
    //    print("read;\t", .{});
    //}
    //print("addr {x:0>4}\n", .{addr});

    //const port = @intToEnum(Ports.PortNames, addr);
    //switch (port) {
    //    .ppu_status => {
    //        log.debug("PPUSTATUS; Flagging vblank to be reset", .{});
    //        self.vblank_clear = true;
    //    },
    //    else => print("PPU Port accessed: {}\n", .{port}),
    //}
}
