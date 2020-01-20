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

pub const PpuState = struct {
    ctrl: PpuCtrl,
    mask: PpuMask,
    oam_addr: u8, // Current OAM address for reading/writing
    mem_address: u16,
    bus_data: u8,
    horiz_pos: u8,
};

/// Read a byte from memory
fn read_memory(state: *PpuState, address: u16) u8 {
    state.access_mode = AccessMode.Read;
    state.mem_address = address;
    suspend {
        state.cur_frame = @frame();
    }
    return state.bus_data;
}

/// Write a byte to memory
fn write_memory(state: *PpuState, address: u16, val: u8) void {
    state.access_mode = AccessMode.Write;
    state.mem_address = address;
    state.bus_data = val;
    suspend {
        state.cur_frame = @frame();
    }
}

/// Write data to OAM, then increment the memory address (write to 0x2003)
fn write_oam_data(state: *PpuState, val: u8) void {}

/// Read data from OAM (read from 0x2003)
fn read_oam_data(state: *PpuState) u8 {}

fn draw_a_pixel(state: *PpuState) void {}

// Data for one line of a tile
const TileRow = struct {
    nametable_data: u8,
    attrib_data: u8,
    pattern_data: [8]u8, // Calculated pattern values for the row
};

fn render_scanline(state: *PpuState, line_num: u8) void {
    // Dummy cycle
    _ = read_memory(state, 0);

    // Fetch data for 32 tiles
    for ([_]u8{0} ** 32) |_, line_tile_num| {
        draw_a_pixel(state);
        draw_a_pixel(state);

        // TODO "The first playfield tile fetched here is actually the 3rd to be drawn on the screen (the playfield data for the first 2 tiles to be rendered on this scanline are fetched at the end of the scanline prior to this one)."
        // I guess there's an 8 byte buffer?
        const tile_num = (line_num / 8) * 32 + line_tile_num;
        const pattern_index = read_nametable(state, tile_num); // TODO read from nametable

        draw_a_pixel(state);
        draw_a_pixel(state);

        const attribute_table_byte = read_memory(state, 0);

        draw_a_pixel(state);
        draw_a_pixel(state);

        const pattern_table_addr = 16 * pattern_index; // TODO probably not 16? Because then the max would be 4096?? Security issue at the very least.
        var pattern_table_low = read_pattern_table(state, pattern_table_addr);

        draw_a_pixel(state);
        draw_a_pixel(state);

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
    }

    // Memory fetch phase
    // (fetch pattern table data for the *next* scanline's objects)
    for ([_]u8{0} ** 8) |_, _| {
        // Read two garbage nametable bytes
        const _ = read_memory(state, 0);
        const _ = read_memory(state, 0);

        const pattern_table_low = read_memory(state, 0);
        const pattern_table_high = read_memory(state, 0);
    }
}

/// Start running the PPU
fn run_ppu(state: *PpuState) void {
    // VINT period
    for ([_]u8{0} ** 341 ** 20) |_, _| {
        _ = read_memory(state, 0); // TODO what address is read?
    }

    // Dummy scanline
    render_scanline(state);

    // Real scanlines
    for ([_]u8{0} ** 240) |_, _| {
        render_scanline(state);
    }

    // Do nothing (vblanking, but no interrupt yet)
    render_scanline(state);

    horiz_pos += 1;
}
