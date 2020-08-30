const assert = @import("std").debug.assert;
const std = @import("std");
const cartridge = @import("cartridge.zig");
const cpu = @import("cpu/cpu.zig");
const ppu = @import("ppu.zig");

pub const BusState = struct {
    cur_frame: anyframe,
    cartridge_mapper: cartridge.NromMapper,
    ppu_state: ppu.PpuState,
    cpu_state: cpu.CpuState,
    internal_ram: [0x800]u8,
    internal_vram: [0x800]u8,
};

fn read_memory(addr: u16, internal_ram: [0x800]u8, cartridge_mapper: cartridge.NromMapper) u8 {
    if (addr < 0x2000) {
        // Mirrors of internal RAM
        return internal_ram[addr % 0x800];
    }
    if (addr >= 0x4020) {
        return cartridge_mapper.readFromCpu(addr);
    }
    std.debug.warn("Read unimplemented address: {X:4}\n", .{addr});
    return 0xFF;
}

fn write_memory(addr: u16, val: u8, internal_ram: *[0x800]u8, internal_vram: *[0x800]u8, cartridge_mapper: *cartridge.NromMapper, ppu_state: *ppu.PpuState) void {
    if (addr < 0x2000) {
        // Mirrors of internal RAM
        internal_ram[addr % 0x800] = val;
        return;
    }
    if (addr >= 0x4020) {
        cartridge_mapper.writeFromCpu(addr, val);
        return;
    }
    if (addr == 0x2007) {
        // TODO do the actual write via the PPU instead of directly doing it here
        const vram_addr = @bitCast(u16, ppu_state.vram_addr);
        if (vram_addr >= 0x3000 and vram_addr <= 0x3EFF) {
            // TODO nametable mirroring
            internal_vram[(vram_addr - 0x3000) % 0x800] = val;
        } else if (vram_addr >= 0x2000 and vram_addr <= 0x3000) {
            internal_vram[(vram_addr - 0x2000) % 0x800] = val;
        } else {
            // FIXME uncomment this once 2006 is implemented!
            // std.debug.warn("PPU write to unimplemented address: {X:4}\n", .{vram_addr});
        }

        ppu.write_ppudata(ppu_state);
        return;
    }
    std.debug.warn("Write unimplemented address: {X:4}\n", .{addr});
}

fn read_ppu_memory(addr: u16, nametable_ram: [0x800]u8, cartridge_mapper: cartridge.NromMapper) u8 {
    if (addr >= 0x2000) {
        if (addr >= 0x3000 and addr <= 0x3EFF) {
            // TODO nametable mirroring
            return nametable_ram[(addr - 0x3000) % 0x800];
        } else if (addr >= 0x2000 and addr <= 0x3000) {
            return nametable_ram[(addr - 0x2000) % 0x800];
        } else {
            std.debug.warn("PPU read from unimplemented address: {X:4}\n", .{addr});
            return 0xFF;
        }
    } else {
        return cartridge_mapper.readFromPpu(addr);
    }
}

pub fn initialize_bus() BusState {
    var cartridge_file = std.fs.cwd().openFile("rom.nes", .{}) catch |err| {
        std.debug.warn("Error opening ROM file: {}\n", .{err});
        std.process.exit(1);
    };
    var cartridge_header_bytes = [_]u8{0} ** 16;
    const bytes_read = cartridge_file.read(cartridge_header_bytes[0..]) catch |err| {
        std.debug.warn("Error reading ROM header: {}\n", .{err});
        std.process.exit(1);
    };
    if (bytes_read < 16) {
        std.debug.warn("Error reading ROM header: unexpected end of file\n", .{});
        std.process.exit(1);
    }

    const cartridge_header = @bitCast(cartridge.INesHeader, cartridge_header_bytes);
    if (!std.mem.eql(u8, cartridge_header.magic[0..], ([_]u8{ 0x4E, 0x45, 0x53, 0x1A })[0..])) {
        std.debug.warn("Unexpected magic bytes in ROM header, not iNES format?", .{});
        std.process.exit(1);
    }

    var cartridge_mapper = cartridge.NromMapper.readFromINes(cartridge_header, &cartridge_file);

    var internal_ram = [_]u8{0} ** 0x800;

    var cpu_state = cpu.initial_state();
    cpu_state.regs.PC = (@intCast(u16, read_memory(0xFFFD, internal_ram, cartridge_mapper)) << 8) | read_memory(0xFFFC, internal_ram, cartridge_mapper);

    return BusState{
        .cur_frame = undefined,
        .ppu_state = ppu.init(),
        .cpu_state = cpu_state,
        .cartridge_mapper = cartridge_mapper,
        .internal_ram = internal_ram,
        .internal_vram = [_]u8{0} ** 0x800,
    };
}

pub fn run(state: *BusState) void {
    _ = async cpu.run_cpu(&state.cpu_state);
    _ = async ppu.run_ppu(&state.ppu_state);

    var cycle_count: usize = 0;
    var was_vblank = false;
    while (cycle_count <= 999999999999999) : (cycle_count += 1) {
        if (ppu.should_trigger_nmi(&state.ppu_state)) {
            // Set the CPU's NMI flag if the PPU is configured to output NMI and is in vblank
            state.cpu_state.nmi_pending = true;
        }

        if (state.cpu_state._current_activity == cpu.CpuActivity.FETCHING_INSTRUCTION) {
            // std.debug.warn("{X:4}\tA:{X:2} X:{X:2} Y:{X:2} P:{X:2} -- {X:2} -- {} -- {},{}\n", .{ state.cpu_state.mem_address, state.cpu_state.regs.A, state.cpu_state.regs.X, state.cpu_state.regs.Y, @bitCast(u8, state.cpu_state.regs.P), read_memory(state.cpu_state.mem_address, state.internal_ram, state.cartridge_mapper), cycle_count + 7, state.ppu_state.vert_pos, state.ppu_state.horiz_pos });
        }
        switch (state.cpu_state.access_mode) {
            cpu.AccessMode.Read => {
                state.cpu_state.bus_data = read_memory(state.cpu_state.mem_address, state.internal_ram, state.cartridge_mapper);
            },
            cpu.AccessMode.Write => {
                write_memory(state.cpu_state.mem_address, state.cpu_state.bus_data, &state.internal_ram, &state.internal_vram, &state.cartridge_mapper, &state.ppu_state);
            },
        }
        resume state.cpu_state.cur_frame;

        state.ppu_state.bus_data = read_ppu_memory(state.ppu_state.mem_address, state.internal_vram, state.cartridge_mapper);
        resume state.ppu_state.cur_frame;

        if (state.ppu_state.stat.in_vblank and !was_vblank) {
            // Give the frontend a chance to draw the PPU's pixels and
            // update input / sound / whatever.
            suspend {
                state.cur_frame = @frame();
            }
        }
        was_vblank = state.ppu_state.stat.in_vblank;
    }
    std.debug.warn("{X:2} {X:2}", .{ state.internal_ram[0x02], state.internal_ram[0x03] });
}
