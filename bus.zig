const std = @import("std");
const cpu = @import("cpu/cpu.zig");

pub fn run() void {
    var cpu_state = cpu.initial_state();
    _ = async cpu.run_cpu(&cpu_state);

    var cycle_count: usize = 0;
    while (cycle_count < 100) : (cycle_count += 1) {
        if (cpu_state._current_activity == cpu.CpuActivity.FETCHING_INSTRUCTION) {
            std.debug.warn("{X:4}\tA:{X:2} X:{X:2} Y:{X:2} P:{X:2}\n", .{ cpu_state.mem_address, cpu_state.regs.A, cpu_state.regs.X, cpu_state.regs.Y, @bitCast(u8, cpu_state.regs.P) });
        }
        cpu_state.bus_data = 0xEA; // no-op
        resume cpu_state.cur_frame;
    }
}
