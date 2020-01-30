const DUMMY_SCANLINE = 261;

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

pub const PpuState = struct {
    ctrl: PpuCtrl,
    mask: PpuMask,
    stat: PpuStatus,
    oam_addr: u8, // Current OAM address for reading/writing
    mem_address: u16,
    bus_data: u8,
    vert_pos: u32,
    horiz_pos: u32,
    buffer_tile: TileRow,
    active_tile: TileRow,
    odd_frame: bool,
    out_framebuffer: [256 * 240]u8, // TODO need more than a byte
};

fn init() PpuState {
    return PpuState{
        .ctrl = @bitCast(PpuCtrl, 0x00),
        .mask = @bitCast(PpuMask, 0x00),
        .stat = @bitCast(PpuStatus, 0x00), // TODO usually starts in vblank actually... And sprite overflow should be set.
        .oam_addr = 0x00,
        .mem_address = 0,
        .bus_data = 0x00,
        .vert_pos = DUMMY_SCANLINE,
        .horiz_pos = 0,
        .buffer_tile = TileRow{
            .nametable_data = 0,
            .attrib_data = 0,
            .pattern_data = [_]u8{0} * 8,
        },
        .active_tile = TileRow{
            .nametable_data = 0,
            .attrib_data = 0,
            .pattern_data = [_]u8{0} * 8,
        },
        .odd_frame = false,
        .out_framebuffer = [_]u8{0} * (256 * 240),
    };
}

/// Read a byte from memory
fn read_memory(state: *PpuState, address: u16) u8 {
    draw_a_pixel(state);
    draw_a_pixel(state);

    state.access_mode = AccessMode.Read;
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
fn fetch_tile(state: *PpuState, line_num: u8, line_tile_num: u8) void {
    const tile_num = (line_num / 8) * 32 + line_tile_num;
    const pattern_index = read_nametable(state, tile_num);

    const attribute_table_byte = read_memory(state, 0);

    const pattern_table_addr = 16 * pattern_index; // TODO probably not 16? Because then the max would be 4096?? Security issue at the very least.
    var pattern_table_low = read_pattern_table(state, pattern_table_addr);
    var pattern_table_high = read_pattern_table(state, pattern_table_addr + 8);

    const tile_row = TileRow{
        .nametable_data = nametable_byte,
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

/// Render the current scanline. Spends 340 PPU cycles.
fn render_scanline(state: *PpuState, line_num: u8) void {
    // Dummy cycle, skipped for the first visible line on odd frames
    if (!(line_num == 0 and odd_frame)) {
        // TODO the address here is the low pattern table address
        // (using the address read during the last line's throwaway cycles)
        _ = read_memory(state, 0); // Cycle 0
    }

    // Fetch data for 32 tiles
    for ([_]u8{0} ** 32) |_, line_tile_num| { // Cycles 1-256 (8*32 = 256)
        fetch_tile(state, line_num, line_tile_num + 2);
    }

    // Fetch pattern table data for the *next* scanline's objects
    for ([_]u8{0} ** 8) |_, _| { // Cycles 257-320 (8*8 = 64)
        // Read two garbage nametable bytes (the same pipeline is used for tiles & sprites)
        const _ = read_memory(state, 0);
        const _ = read_memory(state, 0);

        const pattern_table_low = read_memory(state, 0);
        const pattern_table_high = read_memory(state, 0);
    }

    // Fetch two tiles for the next scanline
    for ([_]u8{0} ** 2) |_, line_tile_num| { // Cycles 321-336 (8*2 = 16)
        fetch_tile(state, line_num + 1, line_tile_num);
    }

    // Fetch two throwaway nametable bytes
    for ([_]u8{0} ** 2) |_, n| { // Cycles 337-340 (2*2 = 4)
        const tile_num = ((line_num + 1) / 8) * 32 + 2 + n;
        _ = read_nametable(state, tile_num);
        _ = read_nametable(state, tile_num);
    }
}

fn set_vblank(state: *PpuState) void {
    state.stat.in_vblank = true;
}

fn unset_vblank(state: *PpuState) void {
    state.stat.in_vblank = false;
}

/// Start running the PPU
fn run_ppu(state: *PpuState) void {
    assert(state.vert_pos == DUMMY_SCANLINE);

    // Dummy scanline
    state.horiz_pos = 0;
    render_scanline(state);

    // Real scanlines
    state.vert_pos = 0;
    for ([_]u8{0} ** 240) |_, _| {
        state.hoiz_pos = 0;
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
