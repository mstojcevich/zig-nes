const c = @cImport({
    @cInclude("SDL2/SDL.h");
});
const bus = @import("bus.zig");
const std = @import("std");

const SDL_WINDOWPOS_UNDEFINED = @bitCast(c_int, c.SDL_WINDOWPOS_UNDEFINED_MASK);

extern fn SDL_PollEvent(event: *c.SDL_Event) c_int;

pub fn main() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const screen = c.SDL_CreateWindow("zig-nes", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 256, 240, c.SDL_WINDOW_OPENGL) orelse {
        c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(screen);

    const renderer = c.SDL_CreateRenderer(screen, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // _ = c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, 255);
    // var i: i32 = 0;
    // while (i < 240) : (i += 1) {
    //     _ = c.SDL_RenderDrawPoint(renderer, i, i);
    // }

    var y: i32 = 0;
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255);
    while (y < 240) : (y += 1) {
        var x: i32 = 0;
        while (x < 240) : (x += 1) {
            // TODO can these SDL functions fail and return something weird?
            var ret = c.SDL_RenderDrawPoint(renderer, y, y);
            if (ret != 0) {
                c.SDL_Log("Fuck? %s", c.SDL_GetError());
                return error.SDLInitializationFailed;
            }
            std.debug.warn("x: {}, y: {}\n", .{ x, y });
        }
    }

    var quit = false;
    var bus_state = bus.initialize_bus();
    _ = async bus.run(&bus_state);
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (SDL_PollEvent(&event) != 0) {
            switch (event.@"type") {
                c.SDL_QUIT => {
                    quit = true;
                },
                else => {},
            }
        }

        var frame_y: i32 = 0;
        while (frame_y < 240) {
            var frame_x: i32 = 0;
            while (frame_x < 256) {
                const color = bus_state.ppu_state.out_framebuffer[@intCast(usize, frame_y * 256 + frame_x)];
                // TODO can these SDL functions fail and return something weird?
                _ = c.SDL_SetRenderDrawColor(renderer, color, color, color, 255);
                _ = c.SDL_RenderDrawPoint(renderer, frame_x, frame_y);
                frame_x += 1;
            }
            frame_y += 1;
        }

        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(17);

        resume bus_state.cur_frame;
    }
}
