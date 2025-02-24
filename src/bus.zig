const assert = @import("std").debug.assert;
const std = @import("std");
const cartridge = @import("cartridge.zig");
const cpu = @import("cpu/cpu.zig");

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

fn write_memory(addr: u16, val: u8, internal_ram: *[0x800]u8, cartridge_mapper: *cartridge.NromMapper) void {
    if (addr < 0x2000) {
        // Mirrors of internal RAM
        internal_ram[addr % 0x800] = val;
        return;
    }
    if (addr >= 0x4020) {
        cartridge_mapper.writeFromCpu(addr, val);
        return;
    }
    std.debug.warn("Write unimplemented address: {X:4}\n", .{addr});
}

pub fn run() void {
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

    var internal_ram = [_]u8{0} ** 0x800; // 2KB of internal RAM

    var cpu_state = cpu.initial_state();
    _ = async cpu.run_cpu(&cpu_state);

    var cycle_count: usize = 0;
    while (cycle_count <= 26547) : (cycle_count += 1) {
        if (cpu_state._current_activity == cpu.CpuActivity.FETCHING_INSTRUCTION) {
            std.debug.warn("{X:4}\tA:{X:2} X:{X:2} Y:{X:2} P:{X:2} -- {X:2} -- {}\n", .{ cpu_state.mem_address, cpu_state.regs.A, cpu_state.regs.X, cpu_state.regs.Y, @bitCast(u8, cpu_state.regs.P), read_memory(cpu_state.mem_address, internal_ram, cartridge_mapper), cycle_count + 7 });
        }
        switch (cpu_state.access_mode) {
            cpu.AccessMode.Read => {
                cpu_state.bus_data = read_memory(cpu_state.mem_address, internal_ram, cartridge_mapper);
            },
            cpu.AccessMode.Write => {
                write_memory(cpu_state.mem_address, cpu_state.bus_data, &internal_ram, &cartridge_mapper);
            },
        }
        resume cpu_state.cur_frame;
    }
}
