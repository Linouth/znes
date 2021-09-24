const std = @import("std");
const print = std.debug.print;
const log = std.log;

const utils = @import("utils.zig");

const Mmu = @import("Mmu.zig");
const Ppu = @This();

// TODOs:
// - MMU for PPU. E.g. to handle mirrors (0x3000-0x3eff & 0x3f20-0x3fff)

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
    ppumask: packed struct {
        const ShowHide = enum(u1) {
            hide,
            show,
        };

        greyscale: enum(u1) {
            normal,
            greyscale,
        } = .normal,
        lm_background: ShowHide = .hide,
        lm_sprites: ShowHide = .hide,
        background: ShowHide = .hide,
        sprites: ShowHide = .hide,
        color_emphasize: packed struct {
            red: bool = false,
            green: bool = false,
            blue: bool = false,
        } = .{},
    } = .{},
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
ppu_ready: bool = false,

frame_row: u9 = 0,
frame_col: u9 = 0,
frame_odd: bool = false,

nmi: *bool,

pub fn init(nmi: *bool) Ppu {
    return Ppu{
        .ports = .{},
        .nmi = nmi,
    };
}

pub fn reset(self: *Ppu) void {
    self.ports.ppuctrl = 0;
    self.ports.ppustatus = 0b10100000;
    self.ports.ppuscroll = 0;
    self.ports.ppudata = 0;
    @panic("Unimplemented");
}

// TODO: Right now each cycle of the PPU is emulated. Instead it might be a good
// idea to do it scanline based instead. Rendering a line when it is ready.
pub fn tick(self: *Ppu) void {

    // TODO: This is a mess. Wayyy too many branches
    if (self.ppu_ready) {
        if (self.frame_col == 0 and self.frame_odd and
            (self.ports.ppumask.background == .show or
                self.ports.ppumask.sprites == .show)) {
            self.frame_col = 1;
        }

        if (self.frame_col == 1) {
            if (self.frame_row == 241) {
                print("VBLANK HIT IN FRAME\n", .{});
                self.ports.ppustatus.vblank = true;

                if (self.ports.ppuctrl & 0x80 > 0)
                    self.nmi.* = true;
            }
            if (self.frame_row == 261) {
                self.vblank_clear = true;
                self.ports.ppustatus.sprite_0_hit = false;
                self.ports.ppustatus.sprite_overflow = false;
            }
        }

        if (self.frame_col >= 340) {
            // Scanline finished, go to next line.
            self.frame_col = 0;
            self.frame_row += 1;
        } else {
            self.frame_col += 1;
        }

        if (self.frame_row > 261) {
            // Frame finished.
            self.frame_row = 0;
            self.frame_odd = !self.frame_odd;
        }
    }

    if (self.vblank_clear) {
        print("vBlankClear SET!\n", .{});
        self.ports.ppustatus.vblank = false;
        self.addr_latch = 0;
        self.vblank_clear = false;
    }

    if (self.ticks == 27384) {
        self.ports.ppustatus.vblank = true;
    } else if (self.ticks == 57165) {
        self.ports.ppustatus.vblank = true;
        self.ppu_ready = true;
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
        },
        .ppu_status => {
            log.debug("PPUSTATUS; Flagging vblank to be reset", .{});
            if (self.ports.ppustatus.vblank) self.vblank_clear = true;
        },
        .oam_addr => {
            print("PPU OAM_ADDR written to: 0x{x}\n", .{data.?});
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
            if (self.ports.ppustatus.vblank == false and
                @bitCast(u8, self.ports.ppumask) & 0x18 > 0) {
                print("vblank: {any}, mask: {any}\n",
                    .{self.ports.ppustatus.vblank, self.ports.ppumask});
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
        //else => {
        //    utils.memDump(self.vram[0..]);
        //    print("PPU Port accessed: {}\n", .{port});
        //    @panic("");
        //},
    }
}
