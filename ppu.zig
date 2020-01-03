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
}

/// Write data to OAM, then increment the memory address (write to 0x2003)
fn write_oam_data(state: *PpuState, val: u8) void {
}

/// Read data from OAM (read from 0x2003)
fn read_oam_data(state: *PpuState) u8 {
}

/// 