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

const Pos = struct {
    x: u32,
    y: u32,
};

pub const UI = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,

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

        const font = c.TTF_OpenFont(font_path, 12)
            orelse return ttfError("TTF_OpenFont");

        const text_generator = TextGen.init(font, renderer);

        return UI {
            .window = window,
            .renderer = renderer,
            .text_gen = text_generator,
        };
    }

    pub fn deinit(self: UI) void {
        defer c.SDL_Quit();
        defer c.TTF_Quit();
        defer c.SDL_DestroyWindow(self.window);
        defer c.SDL_DestroyRenderer(self.renderer);
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
