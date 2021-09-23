const std = @import("std");
const print = std.debug.print;
const log = std.log;

const utils = @import("utils.zig");

const Mmu = @import("Mmu.zig");
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

vram: [0x4000]u8 = .{0xff} ** 0x4000,
vram_addr: u16 = 0,

addr_latch: u16 = 0,
addr_latch_write_toggle: u1 = 0,

ports: Ports,
vblank_clear: bool = false,

ticks: u32 = 0,

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

    if (self.ticks == 27384 or self.ticks == 57165) {
        print("vBlank set to true\n", .{});
        self.ports.ppustatus.vblank = true;
    } else if (self.ticks > 60000 and self.ticks % 32 == 0) {
        self.ports.ppustatus.vblank = true;
    }

    if (self.vblank_clear) {
        print("vBlankClear SET!\n", .{});
        self.ports.ppustatus.vblank = false;
        self.addr_latch = 0;
        self.vblank_clear = false;
    }

    self.ticks += 1;
}

pub fn memoryCallback(ctx: *c_void, map: Mmu.Map, addr: u16, data: ?u8) void {
    const self = @ptrCast(*Ppu, @alignCast(@alignOf(Ppu), ctx));

    print("PPU Memory access; ", .{});
    if (data) |dat| {
        print("write {x:0>2};\t", .{dat});
    } else {
        print("read;\t", .{});
    }
    print("addr {x:0>4}\n", .{addr});

    const port = @intToEnum(Ports.PortNames, addr);
    switch (port) {
        .ppu_ctrl => {
            print("PPU Ctrl accessed\n", .{});
        },
        .ppu_mask => {
            print("PPU Mask accessed\n", .{});

            switch (data.?) {
                0 => {},
                else => @panic("unimplemented"),
            }
        },
        .ppu_status => {
            log.debug("PPUSTATUS; Flagging vblank to be reset", .{});
            if (self.ports.ppustatus.vblank) self.vblank_clear = true;
        },
        .oam_data => {
            @panic("OAM Data accessed");
        },
        .ppu_scroll => {
            const rot = self.addr_latch_write_toggle +% 1;
            if (self.addr_latch & (@as(u16, 0xff) << (@as(u4, rot)*8)) != 0) {
                std.debug.panic("PPU: Writing to PPUSCROLL without addr_latch cleared: {x}", .{self.addr_latch});
            }

            switch (self.addr_latch_write_toggle) {
                0 => self.addr_latch = @as(u16, data.?) << 8,
                1 => {
                    self.addr_latch |= data.?;
                    print("ppu_scroll done: 0x{x}\n", .{self.addr_latch});
                },
            }
            self.addr_latch_write_toggle +%= 1;
        },
        .ppu_addr => {
            switch (self.addr_latch_write_toggle) {
                0 => self.addr_latch = @as(u16, data.?) << 8,
                1 => {
                    self.addr_latch |= data.?;
                    self.vram_addr = self.addr_latch;
                    print("vram_addr set: 0x{x}\n", .{self.vram_addr});
                },
            }
            self.addr_latch_write_toggle +%= 1;
        },
        .ppu_data => {
            if (self.ports.ppustatus.vblank == false or (self.ports.ppumask & 0x18) > 0) {
                print("vblank: {any}, mask: {any}\n", .{self.ports.ppustatus.vblank, self.ports.ppumask});
                @panic("PPU: Trying to access VRAM while screen is still turned on");
            }

            if (data) |dat| {
                // Write
                self.vram[self.vram_addr] = dat;

                print("PPU: DATA write {x} to addr {x}\n", .{dat, self.vram_addr});
                utils.dumpSurroundingHL(self.vram[0..], self.vram_addr);
            } else {
                // read
                @panic("PPU: PPU_DATA read not implemented");
            }

            // (0: add 1, going across; 1: add 32, going down)
            self.vram_addr += if (self.ports.ppuctrl & 4 == 0) @as(u16, 1) else 32;
        },
        .oam_dma => {
            @panic("OAM DMA accessed");
        },
        else => {
            utils.memDump(self.vram[0..]);
            print("PPU Port accessed: {}\n", .{port});
            @panic("");
        },
    }
}
