const cpu = @import("cpu/cpu.zig");

pub fn main() void {
    var cpu_state = cpu.initial_state();
    cpu_state.regs.P.negative = true;
    _ = async cpu.run_cpu(&cpu_state);
    resume cpu_state.cur_frame;
    resume cpu_state.cur_frame;
    resume cpu_state.cur_frame;
}
