const std = @import("std");
const assert = @import("std").debug.assert;

const MirrorArrangement = packed enum(u1) {
    Vertical = 0,
    Horizontal = 1,
};

const TvEncoding = packed enum(u1) {
    NTSC = 0,
    PAL = 1,
};

const TvEncoding2 = packed enum(u2) {
    NTSC = 0,
    DUAL_A = 1,
    PAL = 2,
    DUAL_B = 3,
};

const INesHeader = packed struct {
    magic: [4]u8, // "NES" followed by DOS EOF (0x4E, 0x45, 0x53, 0x1A)
    prg_rom_size: u8, // Size of PRG ROM in 16KiB units
    chr_size: u8, // Size of CHR ROM in 8KiB units (0 means CHR RAM is used)

    // Flags 6
    mirroring: MirrorArrangement,
    persistent_ram: bool,
    has_trainer: bool,
    four_screen_vram: bool, // Ignore the mirroring mode, instead provide four-screen VRAM
    mapper_num_lower: u4,

    // Flags 7
    vs_unisystem: bool,
    playchoice_10: bool, // hint screen data stored after CHR data
    ines_version: u2,
    mapper_num_upper: u4,

    // Flags 8
    prg_ram_size: u8, // Size of PRG RAM in 8KiB units

    // Flags 9
    tv_encoding: TvEncoding,
    reserved_1: u7,

    // Flags 10
    tv_encoding_2: TvEncoding2,
    reserved_2: u2,
    has_prg_ram: bool,
    has_bus_conflicts: bool,
    reserved_3: u2,

    reserved_4: u8,
    reserved_5: u8,
    reserved_6: u8,
    reserved_7: u8,
    reserved_8: u8,
};

test "INesHeader is 16 bytes" {
    assert(@sizeOf(INesHeader) == 16);
}

test "INesHeader bit order smoke test" {
    var header_bytes = [16]u8{
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 3, 0,
        0, 0, 0, 0,
    };
    assert(@bitCast(INesHeader, header_bytes).tv_encoding_2 == TvEncoding2.DUAL_2);
}
