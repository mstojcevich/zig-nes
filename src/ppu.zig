const assert = @import("std").debug.assert;
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const DUMMY_SCANLINE = 241;

const PpuCtrl = packed struct {
    nametable_select: u2,
    increment_mode: bool,
    sprite_tile_select: u1,
    background_tile_select: u1,
    sprite_height: u1,
    master_slave: u1,
    nmi_enable: bool,
};

const PpuMask = packed struct {
    greyscale: bool,
    background_left_column_enable: bool,
    sprite_left_column_enable: bool,
    background_enable: bool,
    sprite_enable: bool,
    color_emphasis_r: bool,
    color_emphasis_g: bool,
    color_emphasis_b: bool,
};

const PpuStatus = packed struct {
    _unused: u5, // Should always be 0 so we can OR the last register read
    sprite_overflow: bool,
    sprite_zero_hit: bool,
    in_vblank: bool,
};

const VramAddr = packed struct {
    coarse_x_scroll: u5,
    coarse_y_scroll: u5,
    horiz_nametable: u1,
    vert_nametable: u1,
    fine_y_scroll: u3,
    _unused: u1,
};

pub const PpuState = struct {
    cur_frame: anyframe,
    ctrl: PpuCtrl,
    stat: PpuStatus,
    vram_addr: VramAddr, // 'v' register
    temp_vram_addr: VramAddr, // 't' register, the address of the top-left onscreen tile
    mem_address: u16,
    bus_data: u8,
    vert_pos: u32,
    horiz_pos: u32,
    buffer_tile: TileRow,
    active_tile: TileRow,
    odd_frame: bool,
    out_framebuffer: [256 * 240]u8, // TODO need more than a byte
};

pub fn init() PpuState {
    return PpuState{
        .cur_frame = undefined,
        .ctrl = @bitCast(PpuCtrl, @as(u8, 0x00)),
        .stat = @bitCast(PpuStatus, @as(u8, 0b10100000)),
        .mem_address = 0,
        .bus_data = 0x00,
        .vert_pos = DUMMY_SCANLINE,
        .horiz_pos = 0,
        .buffer_tile = TileRow{
            .nametable_data = 0,
            .attrib_data = 0,
            .pattern_data = [_]u8{0} ** 8,
        },
        .active_tile = TileRow{
            .nametable_data = 0,
            .attrib_data = 0,
            .pattern_data = [_]u8{0} ** 8,
        },
        .odd_frame = false,
        .out_framebuffer = [_]u8{0} ** (256 * 240),
        .vram_addr = @bitCast(VramAddr, @as(u16, 0x0000)),
        .temp_vram_addr = @bitCast(VramAddr, @as(u16, 0x0000)),
    };
}

/// Read a byte from memory
fn read_memory(state: *PpuState, address: u16) u8 {
    draw_a_pixel(state);
    draw_a_pixel(state);

    state.mem_address = address;
    suspend {
        state.cur_frame = @frame();
    }
    return state.bus_data;
}

/// Write data to OAM, then increment the memory address (write to 0x2003)
fn write_oam_data(state: *PpuState, val: u8) void {}

/// Read data from OAM (read from 0x2003)
fn read_oam_data(state: *PpuState) u8 {}

fn draw_a_pixel(state: *PpuState) void {
    // TODO apply palette
    if (state.horiz_pos > 255 or state.vert_pos == DUMMY_SCANLINE) {
        // Dummy scanline or outside of the visible
        // part of the scanline.
        return;
    }

    // * 64 is just a hack to get decent greyscale visuals before applying a palette
    const tile_x = state.horiz_pos % 8;
    state.out_framebuffer[state.vert_pos * 256 + state.horiz_pos] = state.active_tile.pattern_data[tile_x] * 64;

    state.horiz_pos += 1;
}

/// Data for one line of a tile
const TileRow = struct {
    nametable_data: u8,
    attrib_data: u8,
    pattern_data: [8]u8, // Calculated pattern values for the row
};

/// Fetches tile data and puts it into state.buffer_tile. Spends 8 PPU cycles.
fn fetch_tile(state: *PpuState) void {
    const pattern_index = read_nametable(state);

    const attribute_table_byte = read_attrib(state);

    const pattern_table_addr = 2 * pattern_index;
    var pattern_table_low = read_pattern_table(state, pattern_table_addr);
    var pattern_table_high = read_pattern_table(state, pattern_table_addr + 1);

    increment_coarse_x(&state.vram_addr);

    var tile_row = TileRow{
        .nametable_data = pattern_index,
        .attrib_data = attribute_table_byte,
        .pattern_data = [_]u8{0} ** 8,
    };
    for ([_]u8{0} ** 8) |_, i| {
        // Construct the pattern data from the two bytes we read
        const lower_bit = pattern_table_low & 0b1;
        pattern_table_low >>= 1;
        const upper_bit = pattern_table_high & 0b1;
        pattern_table_high >>= 1;

        tile_row.pattern_data[7 - i] = (upper_bit << 1) | lower_bit;
    }

    // TODO: actual shift register instead of swapping?
    state.active_tile = state.buffer_tile;
    state.buffer_tile = tile_row;
}

/// Read tile data from the nametable
fn read_nametable(state: *PpuState) u8 {
    // v register w/o the horizontal scroll bits. The selected nametable
    // is already part of the v register, as are the coarse x & y offsets.
    const nt_offset = @bitCast(u16, state.vram_addr) & 0x0FFF;
    const nt_address: u16 = 0x2000 | nt_offset;

    return read_memory(state, nt_address);
}

/// Read an attribute byte
fn read_attrib(state: *PpuState) u8 {
    const attrib_base: u16 = 0x23C0
        | (@intCast(u16, state.vram_addr.vert_nametable) << 11)
        | (@intCast(u16, state.vram_addr.horiz_nametable) << 10);

    // Each attrib table entry covers 4 tiles
    const attrib_x: u16 = state.vram_addr.coarse_x_scroll >> 2;
    const attrib_y: u16 = state.vram_addr.coarse_y_scroll >> 2;
    const attrib_offset: u16 = (attrib_y << 3) | attrib_x;

    const attrib_address = attrib_base | attrib_offset;
    return read_memory(state, attrib_base | attrib_offset);
}

/// Read from the pattern table
fn read_pattern_table(state: *PpuState, pattern_table_addr: u16) u8 {
    assert(pattern_table_addr < 0x1000);

    const attrib_table_base: u16 = switch (state.ctrl.background_tile_select) {
        0 => 0x0000, // Attrib table 0: 0x0000-0x0FFF
        1 => 0x1000, // Attrib table 1: 0x1000-0x1FFF
    };

    return read_memory(state, attrib_table_base + pattern_table_addr);
}

/// Render the current scanline. Spends 340 PPU cycles.
fn render_scanline(state: *PpuState) void {
    const line_num = state.vert_pos;

    // Dummy cycle, skipped for the first visible line on odd frames
    if (!(line_num == 0 and state.odd_frame)) {
        // TODO the address here is the low pattern table address
        // (using the address read during the last line's throwaway cycles)
        _ = read_memory(state, 0); // Cycle 0
    }

    // Fetch data for 32 tiles
    for ([_]u8{0} ** 32) |_, _| { // Cycles 1-256 (8*32 = 256)
        fetch_tile(state);
    }

    // TODO when do these happen? Should they happen after the
    // first garbge read_memory below?
    increment_y(&state.vram_addr); // cycle 256?
    // horizontal_reset(&state.vram_addr); // cycle 257?

    // Fetch pattern table data for the *next* scanline's objects
    for ([_]u8{0} ** 8) |_, _| { // Cycles 257-320 (8*8 = 64)
        // Read two garbage nametable bytes (the same pipeline is used for tiles & sprites)
        _ = read_memory(state, 0);
        _ = read_memory(state, 0);

        const pattern_table_low = read_memory(state, 0);
        const pattern_table_high = read_memory(state, 0);
    }

    // Fetch two tiles for the next scanline
    for ([_]u8{0} ** 2) |_, _| { // Cycles 321-336 (8*2 = 16)
        fetch_tile(state);
    }

    // Fetch two throwaway nametable bytes
    for ([_]u8{0} ** 2) |_, n| { // Cycles 337-340 (2*2 = 4)
        _ = read_nametable(state);
        _ = read_nametable(state);
    }
}

fn set_vblank(state: *PpuState) void {
    state.stat.in_vblank = true;
}

fn unset_vblank(state: *PpuState) void {
    state.stat.in_vblank = false;
}

/// Start running the PPU
pub fn run_ppu(state: *PpuState) void {
    assert(state.vert_pos == DUMMY_SCANLINE);

    // Dummy scanline
    state.horiz_pos = 0;
    render_scanline(state);

    // Real scanlines
    state.vert_pos = 0;
    for ([_]u8{0} ** 240) |_, _| {
        state.horiz_pos = 0;
        render_scanline(state);
        state.vert_pos += 1;
    }

    assert(state.vert_pos == 240); // now on the 241st line

    // Do nothing (vblanking, but no interrupt yet)
    for ([_]u8{0} ** 170) |_, _| {
        // TODO what address to read? Whatever was on the bus last?
        _ = read_memory(state, state.mem_address);
    }
    state.vert_pos += 1;

    assert(state.vert_pos == 241);

    // VBlank setting actually happens during the second tick of scanline 241, but this implementation
    // currently only emulates at memory-access accuracy, so it isn't fine-grained enough for that to
    // matter.
    set_vblank(state);
    for ([_]u8{0} ** 170 ** 20) |_, _| {
        // TODO what address to read? Whatever was on the bus last?
        _ = read_memory(state, state.mem_address);
    }
    state.vert_pos += 20;

    state.odd_frame = !state.odd_frame;
    unset_vblank(state);
}

fn increment_coarse_x(vram_addr: *VramAddr) void {
    if (vram_addr.coarse_x_scroll == 31) {
        vram_addr.coarse_x_scroll = 0;
        vram_addr.horiz_nametable +%= 1;
    } else {
        vram_addr.coarse_x_scroll += 1;
    }
}

fn increment_y(vram_addr: *VramAddr) void {
    if (vram_addr.fine_y_scroll == 7) {
        vram_addr.fine_y_scroll = 0;
        if (vram_addr.coarse_y_scroll == 29) {
            vram_addr.coarse_y_scroll = 0;
            vram_addr.vert_nametable +%= 1;
        } else if (vram_addr.coarse_y_scroll == 31) {
            vram_addr.coarse_y_scroll = 0;
        } else {
            vram_addr.coarse_y_scroll += 1;
        }
    } else {
        vram_addr.fine_y_scroll += 1;
    }
}

/// Returns whether the NMI interrupt flag on the CPU should be pulled low.
pub fn should_trigger_nmi(state: *PpuState) bool {
    return state.ctrl.nmi_enable and state.stat.in_vblank;
}
