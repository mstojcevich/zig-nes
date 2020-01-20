const std = @import("std");
const assert = @import("std").debug.assert;

const Cartridge = struct {
    // Read and write values accessible from the CPU
    readFromCpu: fn (addr: u16) u8,
    writeFromCpu: fn (addr: u16, val: u8) void,
    // Read and write values accessible from the PPU
    readFromPpu: fn (addr: u16) u8,
    writeFromPpu: fn (addr: u16, val: u8) void,
};

pub const NromMapper = struct {
    ram: [0x2000]u8, // I think only Family BASIC has this
    rom: [0x8000]u8,
    chr: [0x2000]u8,
    chr_ram: bool,

    const Self = @This();

    fn readFromCpu(self: Self, addr: u16) u8 {
        if (addr < 0x6000) {
            // TODO is this really FF?
            return 0xFF;
        }
        const pgr_addr = addr - 0x6000;
        assert(pgr_addr < 0xA000);

        // TODO what to return if there is no PRG RAM?
        if (pgr_addr < 0x2000) {
            return self.ram[pgr_addr];
        }

        return self.rom[pgr_addr - 0x2000];
    }

    fn writeFromCpu(self: *Self, addr: u16, val: u8) void {
        if (addr < 0x6000) return;
        const pgr_addr = addr - 0x6000;
        assert(pgr_addr < 0xA000);

        if (pgr_addr < 0x2000) {
            self.ram[pgr_addr] = val;
        }
    }

    fn readFromPpu(self: Self, addr: u16) u8 {
        assert(addr < 0x2000);
        return self.chr[addr];
    }

    fn writeFromPpu(self: *Self, addr: u16, val: u8) void {
        // In reality NROM cartridges use CHR ROM
        assert(addr < 0x2000);
        if (chr_ram) {
            self.chr[addr] = val;
        }
    }

    pub fn readFromINes(header: INesHeader, file: *std.fs.File) NromMapper {
        var mapper = NromMapper{
            .ram = [_]u8{0} ** 0x2000,
            .rom = [_]u8{0} ** 0x8000,
            .chr = [_]u8{0} ** 0x2000,
            .chr_ram = header.chr_size == 0,
        };

        if (header.has_trainer) {
            file.seekBy(512) catch |err| {
                std.debug.warn("Error seeking past trainer: {}\n", .{err});
                std.process.exit(1);
            };
        }

        // Read PRG ROM
        if (header.prg_rom_size == 1) {
            // 16KiB repeated
            const bytes_read = file.read(mapper.rom[0..0x4000]) catch |err| {
                std.debug.warn("Error reading PRG rom: {}\n", .{err});
                std.process.exit(1);
            };
            if (bytes_read < 0x4000) {
                std.debug.warn("Error reading PRG rom: unexpected end of file\n", .{});
                std.process.exit(1);
            }
            for (mapper.rom[0..0x4000]) |b, i| mapper.rom[0x4000 + i] = b;
        } else if (header.prg_rom_size == 2) {
            const bytes_read = file.read(mapper.rom[0..0x8000]) catch |err| {
                std.debug.warn("Error reading PRG rom: {}\n", .{err});
                std.process.exit(1);
            };
            if (bytes_read < 0x8000) {
                std.debug.warn("Error reading PRG rom: unexpected end of file\n", .{});
                std.process.exit(1);
            }
        } else {
            std.debug.warn("NROM w/ oversized PRG ROM: {}\n", .{header.prg_rom_size});
            std.process.exit(1);
        }

        // Read CHR ROM
        if (header.chr_size == 1) {
            const bytes_read = file.read(mapper.chr[0..0x2000]) catch |err| {
                std.debug.warn("Error reading CHR rom: {}\n", .{err});
                std.process.exit(1);
            };
            if (bytes_read < 0x2000) {
                std.debug.warn("Error reading CHR rom: unexpected end of file\n", .{});
                std.process.exit(1);
            }
        } else if (header.chr_size != 0) {
            std.debug.warn("NROM w/ oversized CHR ROM: {}\n", .{header.chr_size});
            std.process.exit(1);
        }

        return mapper;
    }
};

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

pub const INesHeader = packed struct {
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
