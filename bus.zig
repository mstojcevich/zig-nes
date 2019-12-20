const std = @import("std");
const cpu = @import("cpu/cpu.zig");

fn read_memory(addr: u16, internal_ram: *[0x800]u8) u8 {
    if (addr < 0x2000) {
        // Mirrors of internal RAM
        return internal_ram[addr % 0x800];
    }
    if (addr >= 0x4020) {
        // TODO cartridge data
        return 0xEA; // no-op
    }
    std.debug.warn("Read unimplemented address: {X:4}\n", .{addr});
    unreachable;
}

fn write_memory(addr: u16, val: u8, internal_ram: *[0x800]u8) void {
    if (addr < 0x2000) {
        // Mirrors of internal RAM
        internal_ram[addr % 0x800] = val;
        return;
    }
    std.debug.warn("Read unimplemented address: {X:4}\n", .{addr});
    unreachable;
}

pub fn run() void {
    var internal_ram = [_]u8{0} ** 0x800; // 2KB of internal RAM

    var cpu_state = cpu.initial_state();
    _ = async cpu.run_cpu(&cpu_state);

    var cycle_count: usize = 0;
    while (cycle_count < 100) : (cycle_count += 1) {
        if (cpu_state._current_activity == cpu.CpuActivity.FETCHING_INSTRUCTION) {
            std.debug.warn("{X:4}\tA:{X:2} X:{X:2} Y:{X:2} P:{X:2}\n", .{ cpu_state.mem_address, cpu_state.regs.A, cpu_state.regs.X, cpu_state.regs.Y, @bitCast(u8, cpu_state.regs.P) });
        }
        switch (cpu_state.access_mode) {
            cpu.AccessMode.Read => {
                cpu_state.bus_data = read_memory(cpu_state.mem_address, &internal_ram);
            },
            cpu.AccessMode.Write => {
                write_memory(cpu_state.mem_address, cpu_state.bus_data, &internal_ram);
            },
        }
        resume cpu_state.cur_frame;
    }
}
