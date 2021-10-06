const std = @import("std");
const log = std.log;

pub const c = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_ttf.h");
});

const SDLError = error{
    SDLError,
    TTFError
};

pub const Pos = struct {
    x: u32,
    y: u32,
};

pub const Rgb = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const UI = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,

    frame_texture: *c.SDL_Texture,

    text_gen: TextGen,


    pub fn init(w: c_int, h: c_int, font_path: [*c]const u8) !UI {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            return sdlError("SDL_Init failed");
        }

        if (c.TTF_Init() < 0) {
            return ttfError("TTF_Init failed");
        }

        const window = c.SDL_CreateWindow(
            "zNES",
            c.SDL_WINDOWPOS_UNDEFINED,
            c.SDL_WINDOWPOS_UNDEFINED,
            w,
            h,
            c.SDL_WINDOW_SHOWN,
        ) orelse return sdlError("SDL_CreateWindow failed");

        const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED)
            orelse return sdlError("SDL_CreateRenderer failed");

        const frame_texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STREAMING,
            Frame.WIDTH, Frame.HEIGHT
        ) orelse return sdlError("SDL_CreateTexture failed");

        const font = c.TTF_OpenFont(font_path, 12)
            orelse return ttfError("TTF_OpenFont");

        const text_generator = TextGen.init(font, renderer);

        return UI {
            .window = window,
            .renderer = renderer,
            .frame_texture = frame_texture,
            .text_gen = text_generator,
        };
    }

    pub fn deinit(self: UI) void {
        defer c.SDL_Quit();
        defer c.TTF_Quit();
        defer c.SDL_DestroyWindow(self.window);
        defer c.SDL_DestroyRenderer(self.renderer);
        defer c.SDL_DestroyTexture(self.frame_texture);
        defer c.SDL_CloseFont(self.text_gen.font);
    }

    pub fn setColor(self: UI, color: c.SDL_Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, color.r, color.g, color.b, color.a);
    }

    pub fn renderClear(self: UI) void {
        _ = c.SDL_RenderClear(self.renderer);
    }

    pub fn present(self: UI) void {
        c.SDL_RenderPresent(self.renderer);
    }

    pub fn renderText(self: UI, str: [*c]const u8, pos: Pos, w: ?u32) void {
        const text = if (w) |width|
            self.text_gen.genTextWrapped(pos, str, width) catch unreachable
         else
            self.text_gen.genText(pos, str) catch unreachable;

        _ = c.SDL_RenderCopy(self.renderer, text.texture, null, &text.rect);
        defer c.SDL_DestroyTexture(text.texture);
    }

    pub fn renderFrame(self: UI, frame: *const Frame) !void {
        //const res = c.SDL_UpdateTexture(self.frame_texture, &Frame.RECT, &frame.data, Frame.WIDTH * 3);
        const res = c.SDL_UpdateTexture(self.frame_texture, &Frame.RECT, &frame.data, Frame.WIDTH * 3);
        if (res < 0) return sdlError("SDL_UpdateTexture failed.");

        _ = c.SDL_RenderCopy(self.renderer, self.frame_texture, null, &Frame.RECT);
    }
};

const TextGen = struct {
    const WHITE = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255};

    const Text = struct {
        texture: *c.SDL_Texture,
        rect: c.SDL_Rect,
    };

    font: *c.TTF_Font,
    renderer: *c.SDL_Renderer,
    color: c.SDL_Color = WHITE,

    fn init(font: *c.TTF_Font, renderer: *c.SDL_Renderer) TextGen {
        return .{
            .font = font,
            .renderer = renderer,
        };
    }

    fn genTextWrapped(self: TextGen, pos: Pos, text: [*c]const u8, w: u32) !Text {
        const surface = c.TTF_RenderText_Blended_Wrapped(self.font, text, self.color, w)
            orelse return ttfError("TTF_RenderText");
        defer c.SDL_FreeSurface(surface);

        return self._genTextFromSurface(pos, surface);
    }

    fn genText(self: TextGen, pos: Pos, text: [*c]const u8) !Text {
        const surface = c.TTF_RenderText_Blended(self.font, text, self.color)
            orelse return ttfError("TTF_RenderText");
        defer c.SDL_FreeSurface(surface);

        return self._genTextFromSurface(pos, surface);
    }

    fn _genTextFromSurface(self: TextGen, pos: Pos, surface: *c.SDL_Surface) !Text {
        return Text {
            .texture = c.SDL_CreateTextureFromSurface(self.renderer, surface)
                orelse return ttfError("SDL_CreateTextureFromSurface"),
            .rect = c.SDL_Rect {
                .x = @bitCast(c_int, pos.x),
                .y = @bitCast(c_int, pos.y),
                .w = surface.*.w,
                .h = surface.*.h,
            },
        };
    }
};


fn sdlError(prefix: []const u8) SDLError {
    const err = c.SDL_GetError();
    log.err("{s}: {s}", .{prefix, err});
    return SDLError.SDLError;
}

fn ttfError(prefix: []const u8) SDLError {
    const err = c.TTF_GetError();
    log.err("{s}: {s}", .{prefix, err});
    return SDLError.TTFError;
}

pub const Frame = struct {
    pub const WIDTH = 256;
    pub const HEIGHT = 240;

    pub const RECT = c.SDL_Rect {
        .x = 0,
        .y = 0,
        .w = WIDTH,
        .h = HEIGHT,
    };

    data: [WIDTH * HEIGHT * 3]u8,

    pub fn init() Frame {
        return Frame {
            .data = .{ 0 } ** (WIDTH * HEIGHT * 3),
        };
    }

    pub fn setPixel(self: *Frame, x: u16, y: u16, rgb: Rgb) void {
        std.debug.assert(x < 256);
        std.debug.assert(y < 240);

        const addr = (y * WIDTH + x) * 3;
        std.debug.assert(addr + 2 < self.data.len);

        self.data[addr] = rgb.r;
        self.data[addr + 1] = rgb.g;
        self.data[addr + 2] = rgb.b;
    }
};
