const std = @import("std");
const assert = @import("std").debug.assert;

const CpuFlags = packed struct {
    carry: bool,
    zero: bool,
    iupt_disable: bool,
    decimal: bool,
    // Not a real value in the register, only in the value pushed to the stack
    // during an interrupt.
    // 1 = software interrupt (brk, php), 0 = hardware interrupt (irq, nmi).
    b_flag: bool,
    // no meaning, always 1
    bit_five: bool,
    overflow: bool,
    negative: bool,
};

test "CPU flag order" { // Negative flag = most significant bit
    var state = initial_state();

    state.regs.P.negative = true;
    assert(@bitCast(u8, state.regs.P) & 0x80 == 0x80);

    state.regs.P.negative = false;
    assert(@bitCast(u8, state.regs.P) & 0x80 == 0x00);
}

const Registers = struct {
    A: u8,
    X: u8,
    Y: u8,
    S: u8,
    PC: u16,
    P: CpuFlags,
};

// Whether the CPU is reading or writing from memory this cycle.
pub const AccessMode = enum {
    Read,
    Write,
};

// Possible CPU activity (used for testing and debugging)
pub const CpuActivity = enum {
    FETCHING_INSTRUCTION,
    EXECUTING_INSTRUCTION,
};

pub const CpuState = struct {
    regs: Registers,
    // The current frame (used for coroutine timing impl)
    cur_frame: anyframe,
    // Each cycle, the CPU either reads or writes from memory.
    // If access_mode is Read, then a byte will be read from
    // the bus. If access_mode is Write, then a byte will be written.
    access_mode: AccessMode,
    // Requested address to read/write bytes from/to each cycle
    mem_address: u16,
    // If access_mode is Read, this is the byte read from memory.
    // If access_mode is Write, this is the byte to write to memory.
    bus_data: u8,
    // Activity the CPU is currently performing. Used for testing and debugging.
    _current_activity: CpuActivity,
};

pub fn initial_state() CpuState {
    comptime var default_p: u8 = 0b00100100;
    return CpuState{
        .regs = Registers{
            .A = 0,
            .X = 0,
            .Y = 0,
            .S = 0xFD,
            .PC = 0xC000,
            .P = @bitCast(CpuFlags, default_p),
        },
        .cur_frame = undefined,
        .access_mode = AccessMode.Read,
        .mem_address = 0,
        .bus_data = 0,
        ._current_activity = CpuActivity.FETCHING_INSTRUCTION,
    };
}

// Read a byte from memory
fn read_memory(state: *CpuState, address: u16) u8 {
    state.access_mode = AccessMode.Read;
    state.mem_address = address;
    suspend {
        state.cur_frame = @frame();
    }
    return state.bus_data;
}

// Write a byte to memory
fn write_memory(state: *CpuState, address: u16, val: u8) void {
    state.access_mode = AccessMode.Write;
    state.mem_address = address;
    state.bus_data = val;
    suspend {
        state.cur_frame = @frame();
    }
}

// Push a byte onto the stack
fn stack_push_u8(state: *CpuState, val: u8) void {
    write_memory(state, 0x0100 | @intCast(u16, state.regs.S), val);
    state.regs.S -%= 1;
}

// Push two bytes onto the stack
fn stack_push_u16(state: *CpuState, val: u16) void {
    stack_push_u8(state, @intCast(u8, val >> 8));
    stack_push_u8(state, @intCast(u8, val & 0xFF));
}

// Pop a byte off of the stack
fn stack_pop_u8(state: *CpuState) u8 {
    state.regs.S +%= 1;
    var val = read_memory(state, 0x0100 | @intCast(u16, state.regs.S));
    return val;
}

// Pop two bytes off of the stack
fn stack_pop_u16(state: *CpuState) u16 {
    var low = stack_pop_u8(state);
    var high = stack_pop_u8(state);
    return @shlExact(@intCast(u16, high), 8) | @intCast(u16, low);
}

// Read memory at PC, then increment PC
fn read_operand(state: *CpuState) u8 {
    var val = read_memory(state, state.regs.PC);
    state.regs.PC +%= 1;
    return val;
}

// Addressing modes
// --------------------------

// Use the instruction operand itself for the operation instead of reading from memory.
fn immediate_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var imm = read_operand(state);
    op(state, imm);
}

// Use a value fetched from the zero page. Absolute addressing of the first 256 bytes of memory.
fn zero_page_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var address = read_operand(state);
    var val = read_memory(state, address);
    op(state, val);
}

fn zero_page_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var address = read_operand(state);
    write_memory(state, address, op(state));
}

fn zero_page_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var address = read_operand(state);
    var val = read_memory(state, address);
    write_memory(state, address, val); // Waste a cycle
    write_memory(state, address, op(state, val));
}

// Use a value in memory at a two-byte long little-endian address.
fn absolute_address_calc(state: *CpuState) u16 {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    return @shlExact(@intCast(u16, high_byte), 8) | low_byte;
}

fn absolute_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var address = absolute_address_calc(state);
    var val = read_memory(state, address);
    op(state, val);
}

fn absolute_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var address = absolute_address_calc(state);
    write_memory(state, address, op(state));
}

fn absolute_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var address = absolute_address_calc(state);
    var val = read_memory(state, address);
    write_memory(state, address, val); // Waste a cycle
    write_memory(state, address, op(state, val));
}

// Access memory at (X + 8-bit operand) % 256
fn indexed_zp_x_address_calc(state: *CpuState) u16 {
    var operand = read_operand(state);
    // Waste a cycle reading
    _ = read_memory(state, @intCast(u16, operand));
    return @intCast(u16, state.regs.X +% operand);
}

fn indexed_zp_x_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var address = indexed_zp_x_address_calc(state);
    var val = read_memory(state, address);
    op(state, val);
}

fn indexed_zp_x_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var address = indexed_zp_x_address_calc(state);
    write_memory(state, address, op(state));
}

fn indexed_zp_x_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var address = indexed_zp_x_address_calc(state);
    var val = read_memory(state, address);
    write_memory(state, address, val); // Waste a cycle
    write_memory(state, address, op(state, val));
}

// Access memory at (Y + 8-bit operand) % 256
fn indexed_zp_y_address_calc(state: *CpuState) u16 {
    var operand = read_operand(state);
    // Waste a cycle reading
    _ = read_memory(state, @intCast(u16, operand));
    return @intCast(u16, state.regs.Y +% operand);
}

fn indexed_zp_y_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var address = indexed_zp_y_address_calc(state);
    var val = read_memory(state, address);
    op(state, val);
}

fn indexed_zp_y_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var address = indexed_zp_y_address_calc(state);
    write_memory(state, address, op(state));
}

fn indexed_zp_y_modify(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var address = indexed_zp_y_address_calc(state);
    var val = read_memory(state, address);
    write_memory(state, address, val); // Waste a cycle
    write_memory(state, address, op(state, val));
}

// Read memory at (X + 16-bit little-endian operand)
fn indexed_abs_x_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.X, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    var val = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
        val = read_memory(state, effective_addr);
    }

    op(state, val);
}

fn indexed_abs_x_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.X, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    _ = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    }
    write_memory(state, effective_addr, op(state));
}

fn indexed_abs_x_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.X, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    _ = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    }
    var val = read_memory(state, effective_addr);
    write_memory(state, effective_addr, val);
    write_memory(state, effective_addr, op(state, val));
}

// Read memory at (Y + 16-bit little-endian operand)
fn indexed_abs_y_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.Y, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    var val = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
        val = read_memory(state, effective_addr);
    }

    op(state, val);
}

fn indexed_abs_y_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.Y, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    var val = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    }
    write_memory(state, effective_addr, op(state));
}

fn indexed_abs_y_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var low_byte = read_operand(state);
    var high_byte = read_operand(state);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.Y, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    _ = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    }
    var val = read_memory(state, effective_addr);
    write_memory(state, effective_addr, val);
    write_memory(state, effective_addr, op(state, val));
}

// Access memory at the 16-bit little-endian address read at (X + (mem at operand)) % 256
fn indexed_indirect_address_calc(state: *CpuState) u16 {
    var pointer = read_operand(state);
    _ = read_memory(state, pointer);

    var low_addr = pointer +% state.regs.X;
    var low_byte = read_memory(state, low_addr);

    var high_addr = pointer +% state.regs.X +% 1;
    var high_byte = read_memory(state, high_addr);

    return @shlExact(@intCast(u16, high_byte), 8) | low_byte;
}

fn indexed_indirect_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var address = indexed_indirect_address_calc(state);
    var val = read_memory(state, address);
    op(state, val);
}

fn indexed_indirect_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var address = indexed_indirect_address_calc(state);
    write_memory(state, address, op(state));
}

fn indexed_indirect_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var address = indexed_indirect_address_calc(state);
    var val = read_memory(state, address);
    write_memory(state, address, val);
    write_memory(state, address, op(state, val));
}

// Read memory at (16-bit little-endian mem at operand) + Y
fn indirect_indexed_read(state: *CpuState, op: fn (*CpuState, u8) void) void {
    var pointer_addr = read_operand(state);

    var low_byte = read_memory(state, pointer_addr);
    var high_byte = read_memory(state, pointer_addr +% 1);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.Y, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    var val = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
        val = read_memory(state, effective_addr);
    }

    op(state, val);
}

fn indirect_indexed_write(state: *CpuState, op: fn (*CpuState) u8) void {
    var pointer_addr = read_operand(state);

    var low_byte = read_memory(state, pointer_addr);
    var high_byte = read_memory(state, pointer_addr +% 1);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.Y, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    var val = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    }

    write_memory(state, effective_addr, op(state));
}

fn indirect_indexed_modify(state: *CpuState, op: fn (*CpuState, u8) u8) void {
    var pointer_addr = read_operand(state);

    var low_byte = read_memory(state, pointer_addr);
    var high_byte = read_memory(state, pointer_addr +% 1);

    var offset_low_byte: u8 = undefined;
    var offset_overflowed = @addWithOverflow(u8, low_byte, state.regs.Y, &offset_low_byte);

    var effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    _ = read_memory(state, effective_addr);
    if (offset_overflowed) { // Oops!
        high_byte +%= 1;
        effective_addr = @shlExact(@intCast(u16, high_byte), 8) | offset_low_byte;
    }
    var val = read_memory(state, effective_addr);

    write_memory(state, effective_addr, val);
    write_memory(state, effective_addr, op(state, val));
}

// Perform a relative branch, using op as the test
fn branch_relative(state: *CpuState, op: fn (*CpuState) bool) void {
    var operand = read_operand(state);
    var branch_taken = op(state);
    if (branch_taken) {
        _ = read_memory(state, state.regs.PC);

        var low_byte = @intCast(u8, state.regs.PC & 0xFF);
        var high_byte = @intCast(u8, state.regs.PC >> 8);

        var signed_operand = @bitCast(i8, operand);
        var new_pc = @intCast(i32, state.regs.PC) + signed_operand;
        var offset_low_byte = @intCast(u8, new_pc & 0xFF);
        var offset_high_byte = @intCast(u8, new_pc >> 8);

        if (offset_high_byte != high_byte) {
            // Oops!
            var oops_read_pc = @shlExact(@intCast(u16, high_byte), 8) | @intCast(u16, offset_low_byte);
            _ = read_memory(state, oops_read_pc);
        }

        state.regs.PC = @shlExact(@intCast(u16, offset_high_byte), 8) | @intCast(u16, offset_low_byte);
    }
}

// Jump to an absolute address
fn jmp_absolute(state: *CpuState) void {
    var address = absolute_address_calc(state);
    state.regs.PC = address;
}

// Jump indirectly "through" a value in memory
// e.g. JMP 00 00 will jump to the 16-bit address stored in memory at 0x0000 and 0x0001
fn jmp_through(state: *CpuState) void {
    var addr_low = read_operand(state);
    var addr_high = read_operand(state);

    var target_low_addr = @shlExact(@intCast(u16, addr_high), 8) | addr_low;
    // Intentionally not handling page crossing
    var target_high_addr = @shlExact(@intCast(u16, addr_high), 8) | (addr_low +% 1);

    var target_low = read_memory(state, target_low_addr);
    var target_high = read_memory(state, target_high_addr);

    state.regs.PC = @shlExact(@intCast(u16, target_high), 8) | target_low;
}

test "jmp_through doesn't cross pages" {
    // Instead of crossing a page boundary, the low byte wraps around to 00 on the same page
    var cpu_state = initial_state();
    _ = async jmp_through(&cpu_state);
    cpu_state.bus_data = 0xFF;
    resume cpu_state.cur_frame;
    cpu_state.bus_data = 0x00;

    resume cpu_state.cur_frame;
    assert(cpu_state.mem_address == 0x00FF); // Fetch low byte
    cpu_state.bus_data = 0xBE;

    resume cpu_state.cur_frame;
    assert(cpu_state.mem_address == 0x0000); // Fetch high byte
    cpu_state.bus_data = 0xBA;

    resume cpu_state.cur_frame;
    assert(cpu_state.regs.PC == 0xBABE);
}

// Instruction impls
// --------------------------

// Read operations
// --------------------------

// Add with carry
fn adc(state: *CpuState, val: u8) void {
    var result: u8 = undefined;
    var carry = @addWithOverflow(u8, state.regs.A, val, &result);
    carry = carry or @addWithOverflow(u8, result, if (state.regs.P.carry) @as(u8, 1) else @as(u8, 0), &result);

    state.regs.P.carry = carry;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;
    // Overflow = "is the sign bit incorrect?"
    state.regs.P.overflow = ((state.regs.A ^ val) & 0x80) == 0 and ((state.regs.A ^ result) & 0x80) > 0;
    state.regs.A = result;
}

test "ADC simple" {
    var state = initial_state();

    state.regs.A = 4;
    adc(&state, 2);

    assert(state.regs.A == 6);
    assert(state.regs.P.carry == false);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == false);
}

test "ADC with carry flag" {
    var state = initial_state();

    state.regs.A = 4;
    state.regs.P.carry = true;
    adc(&state, 2);

    assert(state.regs.A == 7);
    assert(state.regs.P.carry == false);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == false);
}

test "ADC negative" {
    var state = initial_state();

    state.regs.A = 4;
    adc(&state, @bitCast(u8, @as(i8, -5)));

    assert(@bitCast(i8, state.regs.A) == -1);
    assert(state.regs.P.carry == false);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == true);
    assert(state.regs.P.zero == false);
}

test "ADC negative becomes zero" {
    // Negative result becomes zero because the carry
    // flag was originally set.
    var state = initial_state();

    state.regs.A = 4;
    state.regs.P.carry = true;
    adc(&state, @bitCast(u8, @as(i8, -5)));

    assert(@bitCast(i8, state.regs.A) == 0);
    assert(state.regs.P.carry == true);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == true);
}

test "ADC overflow but no carry" {
    // i.e. unsigned is correct, but signed is incorrect
    var state = initial_state();

    // Output has doesn't set carry, but overflows (overflow into bit 7)
    state.regs.A = 127;
    state.regs.P.carry = false;
    adc(&state, 1);

    assert(state.regs.A == 128);
    assert(state.regs.P.carry == false);
    assert(state.regs.P.overflow == true);
    assert(state.regs.P.negative == true);
    assert(state.regs.P.zero == false);
}

test "ADC overflow but no carry (because of carry flag)" {
    // i.e. unsigned is correct, but signed is incorrect
    var state = initial_state();

    // The carry bit is considered when determining overflow
    state.regs.A = 127;
    state.regs.P.carry = true;
    adc(&state, 0);

    assert(state.regs.A == 128);
    assert(state.regs.P.carry == false);
    assert(state.regs.P.overflow == true);
    assert(state.regs.P.negative == true);
    assert(state.regs.P.zero == false);
}

test "ADC carry and overflow" {
    // i.e. both unsigned and signed are incorrect
    var state = initial_state();

    // Output has both carry and overflow (carry into bit 7, bit 7 already set, adding to bit 7, carry into bit 8)
    state.regs.A = @bitCast(u8, @as(i8, -100)); // (156)
    adc(&state, @bitCast(u8, @as(i8, -100))); // (156)

    assert(state.regs.A == 56);
    assert(state.regs.P.carry == true);
    assert(state.regs.P.overflow == true);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == false);
}

test "ADC carry but no overflow" {
    // i.e. signed answer is correct, but unsigned is wrong
    var state = initial_state();

    // Output has carry but no overflow (no carry into bit 7, bit 7 set, adding to bit 7, carry into bit 8)
    state.regs.A = 0b01000000; // 64
    adc(&state, 0b11000000); // 192 (-64)

    assert(state.regs.A == 0);
    assert(state.regs.P.carry == true);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == true);
}

test "ADC carry but no overflow (alt)" {
    // i.e. signed answer is correct, but unsigned is wrong
    var state = initial_state();

    // Output has carry but no overflow (no carry into bit 7, bit 7 set, adding to bit 7, carry into bit 8)
    state.regs.A = 100;
    adc(&state, @bitCast(u8, @as(i8, -20)));

    assert(state.regs.A == 80);
    assert(state.regs.P.carry == true);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == false);
}

test "ADC carry but no overflow (because of carry flag)" {
    // i.e. signed answer is correct, but unsigned is wrong
    var state = initial_state();

    // Output has carry but no overflow (carry into bit 7, bit 7 unset, adding to bit 7, carry into bit 8)
    state.regs.A = 0b00111111; // 63
    state.regs.P.carry = true; // + 1
    adc(&state, 0b11000000); // 192 (-64)

    assert(state.regs.A == 0);
    assert(state.regs.P.carry == true);
    assert(state.regs.P.overflow == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.zero == true);
}

// Bitwise AND
fn and_op(state: *CpuState, val: u8) void {
    state.regs.A &= val;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = state.regs.A & (0b10000000) != 0;
}

// Bitwise AND, then LSR A
fn alr(state: *CpuState, val: u8) void {
    and_op(state, val);
    state.regs.A = lsr(state, state.regs.A);
}

// Bitewise AND, then ROR A
fn arr(state: *CpuState, val: u8) void {
    and_op(state, val);
    state.regs.A = ror(state, state.regs.A);
}

// Bit test
fn bit(state: *CpuState, val: u8) void {
    state.regs.P.zero = (state.regs.A & val) == 0;
    state.regs.P.overflow = (val & 0b01000000) != 0;
    state.regs.P.negative = (val & 0b10000000) != 0;
}

// Set flags based on A-val
fn cmp(state: *CpuState, val: u8) void {
    var result: u8 = undefined;
    var overflow = @subWithOverflow(u8, state.regs.A, val, &result);

    state.regs.P.carry = !overflow;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;
}

test "cmp basic equal" {
    var state = initial_state();
    state.regs.A = 0x04;
    cmp(&state, 0x04);

    assert(state.regs.A == 0x04);
    assert(state.regs.P.zero == true);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.carry == true);
}

test "cmp val > a" {
    var state = initial_state();
    state.regs.A = 0x04;
    cmp(&state, 0x05);

    assert(state.regs.A == 0x04);
    assert(state.regs.P.zero == false);
    assert(state.regs.P.negative == true);
    assert(state.regs.P.carry == false);
}

test "cmp val < a" {
    var state = initial_state();
    state.regs.A = 0x04;
    cmp(&state, 0x03);

    assert(state.regs.A == 0x04);
    assert(state.regs.P.zero == false);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.carry == true);
}

test "cmp val = a w/ big values" {
    var state = initial_state();
    state.regs.A = 0xFF; // 0xFF + 0x01 = 0x100
    cmp(&state, 0xFF);

    assert(state.regs.A == 0xFF);
    assert(state.regs.P.zero == true);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.carry == true);
}

test "cmp zero with zero" {
    var state = initial_state();
    state.regs.A = 0;
    cmp(&state, 0);

    assert(state.regs.A == 0x00);
    assert(state.regs.P.zero == true);
    assert(state.regs.P.negative == false);
    assert(state.regs.P.carry == true);
}

// Set flags based on X-val
fn cpx(state: *CpuState, val: u8) void {
    var result: u8 = undefined;
    var overflow = @subWithOverflow(u8, state.regs.X, val, &result);

    state.regs.P.carry = !overflow;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;
}

// Set flags based on Y-val
fn cpy(state: *CpuState, val: u8) void {
    var result: u8 = undefined;
    var overflow = @subWithOverflow(u8, state.regs.Y, val, &result);

    state.regs.P.carry = !overflow;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;
}

// A = A xor val
fn eor(state: *CpuState, val: u8) void {
    state.regs.A ^= val;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// A and X = val
fn lax(state: *CpuState, val: u8) void {
    state.regs.A = val;
    state.regs.X = val;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// A = val
fn lda(state: *CpuState, val: u8) void {
    state.regs.A = val;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// X = val
fn ldx(state: *CpuState, val: u8) void {
    state.regs.X = val;
    state.regs.P.zero = state.regs.X == 0;
    state.regs.P.negative = (state.regs.X & 0b10000000) != 0;
}

// Y = val
fn ldy(state: *CpuState, val: u8) void {
    state.regs.Y = val;
    state.regs.P.zero = state.regs.Y == 0;
    state.regs.P.negative = (state.regs.Y & 0b10000000) != 0;
}

fn las(state: *CpuState, val: u8) void {
    var result = val & state.regs.S;
    state.regs.A = result;
    state.regs.X = result;
    state.regs.S = result;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// no-op
fn nop(state: *CpuState) void {}

// no-op (ignore arg)
fn ign(state: *CpuState, val: u8) void {}

// Bitwise OR
fn ora(state: *CpuState, val: u8) void {
    state.regs.A |= val;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// A & immediate, sets carry flag to the negative flag
fn anc(state: *CpuState, val: u8) void {
    and_op(state, val);
    state.regs.P.carry = state.regs.P.negative;
}

// Subtract with carry
fn sbc(state: *CpuState, val: u8) void {
    var result: u8 = undefined;
    var carry = @subWithOverflow(u8, state.regs.A, val, &result);
    carry = carry or @subWithOverflow(u8, result, if (state.regs.P.carry) @as(u8, 0) else @as(u8, 1), &result);

    state.regs.P.carry = !carry;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;
    // Overflow = "is the sign bit incorrect?"
    state.regs.P.overflow = ((state.regs.A ^ ~val) & 0x80) == 0 and ((state.regs.A ^ result) & 0x80) > 0;
    state.regs.A = result;
}

// Read-write operations
// --------------------------

// Shift left by 1 bit
fn asl(state: *CpuState, val: u8) u8 {
    var result: u8 = undefined;
    var carry = @shlWithOverflow(u8, val, 1, &result);

    state.regs.P.carry = carry;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;

    return result;
}

// Decrement by 1
fn dec(state: *CpuState, val: u8) u8 {
    var result = val -% 1;

    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;

    return result;
}

// Increment by 1
fn inc(state: *CpuState, val: u8) u8 {
    var result = val +% 1;

    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;

    return result;
}

// Increment by 1, then SBC from A
fn isc(state: *CpuState, val: u8) u8 {
    var result = inc(state, val);
    sbc(state, result); // TODO ASAP does this output to the accumulator or memory??
    return result;
}

// Logical right-shift (highest bit is always set to 0)
fn lsr(state: *CpuState, val: u8) u8 {
    var result = val >> 1;

    state.regs.P.carry = (val & 0b1) != 0;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;

    return result;
}

// Rotate one bit left, then AND with the accumulator
fn rla(state: *CpuState, val: u8) u8 {
    var result: u8 = rol(state, val);
    and_op(state, result);
    // XXX do I do the right thing with flags for these undocumented combined ops?
    return result;
}

// Rotate one bit left
fn rol(state: *CpuState, val: u8) u8 {
    var result: u8 = undefined;
    var overflowed = @shlWithOverflow(u8, val, 1, &result);
    result |= if (state.regs.P.carry) @as(u8, 1) else @as(u8, 0);

    state.regs.P.carry = overflowed;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;

    return result;
}

// Rotate one bit right
fn ror(state: *CpuState, val: u8) u8 {
    var old_bit_zero = (val & 0b1) != 0;
    var result = val >> 1;
    result |= if (state.regs.P.carry) @as(u8, 0x80) else @as(u8, 0x00);

    state.regs.P.carry = old_bit_zero;
    state.regs.P.zero = result == 0;
    state.regs.P.negative = (result & 0b10000000) != 0;

    return result;
}

// Rotate one bit right, then ADC to the accumulator
fn rra(state: *CpuState, val: u8) u8 {
    var result = ror(state, val);
    adc(state, result);
    return result;
}

// Shift one bit left, then OR with the accumulator
fn slo(state: *CpuState, val: u8) u8 {
    var result = asl(state, val);
    ora(state, result);
    return result;
}

// Shift one bit right, then XOR with the accumulator
fn sre(state: *CpuState, val: u8) u8 {
    var result = lsr(state, val);
    eor(state, result);
    return result;
}

// Write operations
// --------------------------

// Store A & X & (address high byte + 1)
fn ahx(state: *CpuState) u8 {
    // Differs from some documentation, but verified with visual6502
    // TODO verify overflow behavior
    return state.regs.A & state.regs.X & (@intCast(u8, state.mem_address >> 8) +% 1);
}

// AHX, then X = A & X
fn tas(state: *CpuState) u8 { // aka SHS
    var result = ahx(state);
    state.regs.X &= state.regs.A;
    state.regs.P.zero = state.regs.X == 0;
    state.regs.P.negative = (state.regs.X & 0b10000000) != 0;

    // TODO: "The value to be stored is copied also to ADDR_HI if page boundary is crossed."
    return result;
}

// Store A & X
fn sax(state: *CpuState) u8 {
    return state.regs.A & state.regs.X;
}

// Store X & (address high byte + 1)
fn shx(state: *CpuState) u8 {
    // TODO verify how this behaves with overflow
    return state.regs.X & (@intCast(u8, state.mem_address >> 8) +% 1);
}

// Store Y & (address high byte + 1)
fn shy(state: *CpuState) u8 {
    // TODO verify how this behaves with overflow
    return state.regs.Y & (@intCast(u8, state.mem_address >> 8) +% 1);
}

// Store A
fn sta(state: *CpuState) u8 {
    return state.regs.A;
}

// Store X
fn stx(state: *CpuState) u8 {
    return state.regs.X;
}

// Store Y
fn sty(state: *CpuState) u8 {
    return state.regs.Y;
}

// Special and implied operations
// (perform their own reads and writes)
// --------------------------

// Forces an interrupt
fn brk(state: *CpuState) void {
    _ = read_operand(state); // throw away the next instruction byte
    // There's no real "b" flag, it's only set in the value pushed to the stack.
    // (it's used to distinguish whether it's a software or hardware interrupt)
    var p_for_stack = @bitCast(u8, state.regs.P) | 0b00010000;
    stack_push_u16(state, state.regs.PC);
    stack_push_u8(state, p_for_stack);
    state.regs.P.iupt_disable = true;

    // TODO NMI can hijack a BRK
    var dest_addr = @intCast(u16, read_memory(state, 0xFFFE));
    dest_addr |= @shlExact(@intCast(u16, read_memory(state, 0xFFFF)), 8);

    state.regs.PC = dest_addr;
}

// Return from interrupt - pull flags & pc from the stack
fn rti(state: *CpuState) void {
    _ = read_memory(state, state.regs.PC); // waste a cycle
    _ = read_memory(state, 0x0100 | @intCast(u16, state.regs.S)); // waste a cycle

    var p_val = stack_pop_u8(state);
    // Even though it's not real, always keep "b" flag as zero when stored for consistency.
    p_val &= 0b11101111;
    // Even though it's not real, always keep bit 5 set, since it's always written as set.
    p_val |= 0b00100000;

    state.regs.P = @bitCast(CpuFlags, p_val);
    state.regs.PC = stack_pop_u16(state);
}

// Pushes the status register to the stack (with the b flag set)
fn php(state: *CpuState) void {
    _ = read_memory(state, state.regs.PC); // waste a cycle
    // There's no real "b" flag, it's only set in the value pushed to the stack.
    // (it's used to distinguish whether it's a software or hardware interrupt)
    var p_for_stack = @bitCast(u8, state.regs.P) | 0b00010000;
    stack_push_u8(state, p_for_stack);
}

// Pushes accumulator onto the stack
fn pha(state: *CpuState) void {
    _ = read_memory(state, state.regs.PC); // waste a cycle
    stack_push_u8(state, state.regs.A);
}

// Pops the status register off of the stack
fn plp(state: *CpuState) void {
    _ = read_memory(state, state.regs.PC); // waste a cycle
    _ = read_memory(state, 0x0100 | @intCast(u16, state.regs.S)); // waste a cycle
    var val = stack_pop_u8(state);
    // Even though it's not real, always keep "b" flag as zero when stored for consistency.
    val &= 0b11101111;
    // Even though it's not real, always keep bit 5 set, since it's always written as set.
    val |= 0b00100000;
    state.regs.P = @bitCast(CpuFlags, val);
}

// Pops the accumulator off of the stack
fn pla(state: *CpuState) void {
    _ = read_memory(state, state.regs.PC); // waste a cycle
    _ = read_memory(state, 0x0100 | @intCast(u16, state.regs.S)); // waste a cycle
    var val = stack_pop_u8(state);
    state.regs.A = val;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// Pops the PC off of the stack, then increments it
fn rts(state: *CpuState) void {
    _ = read_memory(state, state.regs.PC); // waste a cycle
    _ = read_memory(state, 0x0100 | @intCast(u16, state.regs.S)); // waste a cycle
    var new_pc = stack_pop_u16(state);
    state.regs.PC = new_pc;
    _ = read_memory(state, state.regs.PC); // waste a cycle
    state.regs.PC +%= 1;
}

// Pushes the PC onto the stack, then jumps to absolute address
fn jsr(state: *CpuState) void {
    var pcl = read_operand(state);
    _ = read_memory(state, 0x0100 | @intCast(u16, state.regs.S)); // waste a cycle
    stack_push_u16(state, state.regs.PC);
    var pch = read_operand(state);
    state.regs.PC = @shlExact(@intCast(u16, pch), 8) | @intCast(u16, pcl);
}

// An invalid opcode was hit that halts the processor
fn stp(state: *CpuState) void {
    // TODO do something to simulate the halt (so that other components still run, but the CPU does nothing)
    std.debug.warn("Illegal opcode encountered, the CPU would normally crash here!\n", .{});
    unreachable;
}

// Clear the carry flag
fn clc(state: *CpuState) void {
    state.regs.P.carry = false;
}

// Set the carry flag
fn sec(state: *CpuState) void {
    state.regs.P.carry = true;
}

// Clear the interrupt disable flag
fn cli(state: *CpuState) void {
    state.regs.P.iupt_disable = false;
}

// Set the interrupt disable flag
fn sei(state: *CpuState) void {
    state.regs.P.iupt_disable = true;
}

// Clear the overflow flag
fn clv(state: *CpuState) void {
    state.regs.P.overflow = false;
}

// Clear the decimal-mode flag
fn cld(state: *CpuState) void {
    state.regs.P.decimal = false;
}

// Set the decimal-mode flag
fn sed(state: *CpuState) void {
    state.regs.P.decimal = true;
}

// Decrement the Y register
fn dey(state: *CpuState) void {
    state.regs.Y -%= 1;
    state.regs.P.zero = state.regs.Y == 0;
    state.regs.P.negative = (state.regs.Y & 0b10000000) != 0;
}

// Increment the Y register
fn iny(state: *CpuState) void {
    state.regs.Y +%= 1;
    state.regs.P.zero = state.regs.Y == 0;
    state.regs.P.negative = (state.regs.Y & 0b10000000) != 0;
}

// Decrement the X register
fn dex(state: *CpuState) void {
    state.regs.X -%= 1;
    state.regs.P.zero = state.regs.X == 0;
    state.regs.P.negative = (state.regs.X & 0b10000000) != 0;
}

// Increment the X register
fn inx(state: *CpuState) void {
    state.regs.X +%= 1;
    state.regs.P.zero = state.regs.X == 0;
    state.regs.P.negative = (state.regs.X & 0b10000000) != 0;
}

// A = Y
fn tya(state: *CpuState) void {
    state.regs.A = state.regs.Y;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// Y = A
fn tay(state: *CpuState) void {
    state.regs.Y = state.regs.A;
    state.regs.P.zero = state.regs.Y == 0;
    state.regs.P.negative = (state.regs.Y & 0b10000000) != 0;
}

// A = X
fn txa(state: *CpuState) void {
    state.regs.A = state.regs.X;
    state.regs.P.zero = state.regs.A == 0;
    state.regs.P.negative = (state.regs.A & 0b10000000) != 0;
}

// X = A
fn tax(state: *CpuState) void {
    state.regs.X = state.regs.A;
    state.regs.P.zero = state.regs.X == 0;
    state.regs.P.negative = (state.regs.X & 0b10000000) != 0;
}

// X = S
fn tsx(state: *CpuState) void {
    state.regs.X = state.regs.S;
    state.regs.P.zero = state.regs.X == 0;
    state.regs.P.negative = (state.regs.X & 0b10000000) != 0;
}

// S = X
fn txs(state: *CpuState) void {
    state.regs.S = state.regs.X;
}

// Test for "branch if negative"
fn bmi(state: *CpuState) bool {
    return state.regs.P.negative;
}

// Test for "branch if positive"
fn bpl(state: *CpuState) bool {
    return !state.regs.P.negative;
}

// Test for "branch if equal"
fn beq(state: *CpuState) bool {
    return state.regs.P.zero;
}

// Test for "branch if not equal"
fn bne(state: *CpuState) bool {
    return !state.regs.P.zero;
}

// Test for "branch if carry set"
fn bcs(state: *CpuState) bool {
    return state.regs.P.carry;
}

// Test for "branch if carry clear"
fn bcc(state: *CpuState) bool {
    return !state.regs.P.carry;
}

// Test for "branch if overflow set"
fn bvs(state: *CpuState) bool {
    return state.regs.P.overflow;
}

// Test for "branch if overflow clear"
fn bvc(state: *CpuState) bool {
    return !state.regs.P.overflow;
}

test "Instruction timings (simple)" {
    // Simple sanity check for instruction timing, doesn't take in account
    // variable timing (like when crossing a page boundary, or branch taken)
    const timings = [_]u8{
        7, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6, // 0F
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 1F
        6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6, // 2F
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 3F
        6, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6, // 4F
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 5F
        6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6, // 6F
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 7F
        2, 6, 0, 6, 3, 3, 3, 3, 2, 2, 2, 0, 4, 4, 4, 4, // 8F
        2, 6, 0, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5, // 9F
        2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4, // AF
        2, 5, 0, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4, // BF
        2, 6, 2, 0, 3, 3, 5, 0, 2, 2, 2, 0, 4, 4, 6, 0, // CF
        2, 5, 0, 0, 4, 4, 6, 0, 2, 4, 2, 0, 4, 4, 7, 0, // DF
        2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6, // EF
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // FF
    };
    for (timings) |expected_cycles, opcode| {
        if (expected_cycles == 0) { // unimplemented or stp instruction
            continue;
        }

        var cpu_state = initial_state();
        cpu_state.regs.P.negative = opcode != 0x30; // Branch if minus
        cpu_state.regs.P.overflow = opcode != 0x70; // Branch if overflow set
        cpu_state.regs.P.carry = opcode != 0xB0; // Branch if carry set
        cpu_state.regs.P.zero = opcode != 0xF0; // Branch if equal

        // Run the fetch cycle
        _ = async run_cpu(&cpu_state);
        cpu_state.bus_data = @intCast(u8, opcode);
        resume cpu_state.cur_frame;
        cpu_state.bus_data = 0;

        var cycles: u8 = 1;
        while (cpu_state._current_activity == CpuActivity.EXECUTING_INSTRUCTION) {
            resume cpu_state.cur_frame;
            cycles += 1;
        }
        if (cycles != expected_cycles) {
            std.debug.warn("{X:2}: {} != {}\n", .{ opcode, expected_cycles, cycles });
        }
        assert(cycles == expected_cycles);
    }
}

test "PC wraparound" {
    // After FFFF, the PC wraps around to 0000
    var state = initial_state();
    state.regs.PC = 0xFFFF;
    _ = async run_cpu(&state);

    // Read instruction
    assert(state.mem_address == 0xFFFF);
    state.bus_data = 0xEA; // no-op
    resume state.cur_frame;

    // Dummy-read cycle
    assert(state.mem_address == 0x0000);
    resume state.cur_frame;

    // Read next instruction
    assert(state.mem_address == 0x0000);
}

test "PC wraparound (operand)" {
    // The operand to an instruction at FFFF is at 0000
    var state = initial_state();
    state.regs.PC = 0xFFFF;
    state.regs.A = 12;
    _ = async run_cpu(&state);

    // Read instruction
    assert(state.mem_address == 0xFFFF);
    state.bus_data = 0x69; // ADC immediate
    resume state.cur_frame;

    // Read immediate
    assert(state.mem_address == 0x0000);
    state.bus_data = 3;
    resume state.cur_frame;

    assert(state.regs.A == 15);
}

// Run the CPU for one cycle (until a suspend point is reached)
pub fn run_cpu(state: *CpuState) void {
    while (true) {
        state._current_activity = CpuActivity.FETCHING_INSTRUCTION;
        var opcode = read_memory(state, state.regs.PC);
        state.regs.PC +%= 1;
        state._current_activity = CpuActivity.EXECUTING_INSTRUCTION;

        switch (opcode) {
            0x0 => {
                brk(state);
            },
            0x1 => {
                indexed_indirect_read(state, ora);
            },
            0x2 => {
                stp(state);
            },
            0x3 => {
                indexed_indirect_modify(state, slo);
            },
            0x4 => {
                zero_page_read(state, ign);
            },
            0x5 => {
                zero_page_read(state, ora);
            },
            0x6 => {
                zero_page_modify(state, asl);
            },
            0x7 => {
                zero_page_modify(state, slo);
            },
            0x8 => {
                php(state);
            },
            0x9 => {
                immediate_read(state, ora);
            },
            0xa => {
                state.regs.A = asl(state, state.regs.A);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xb => {
                immediate_read(state, anc);
            },
            0xc => {
                absolute_read(state, ign);
            },
            0xd => {
                absolute_read(state, ora);
            },
            0xe => {
                absolute_modify(state, asl);
            },
            0xf => {
                absolute_modify(state, slo);
            },
            0x10 => {
                branch_relative(state, bpl);
            },
            0x11 => {
                indirect_indexed_read(state, ora);
            },
            0x12 => {
                stp(state);
            },
            0x13 => {
                indirect_indexed_modify(state, slo);
            },
            0x14 => {
                indexed_zp_x_read(state, ign);
            },
            0x15 => {
                indexed_zp_x_read(state, ora);
            },
            0x16 => {
                indexed_zp_x_modify(state, asl);
            },
            0x17 => {
                indexed_zp_x_modify(state, slo);
            },
            0x18 => {
                clc(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x19 => {
                indexed_abs_y_read(state, ora);
            },
            0x1a => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x1b => {
                indexed_abs_y_modify(state, slo);
            },
            0x1c => {
                indexed_abs_x_read(state, ign);
            },
            0x1d => {
                indexed_abs_x_read(state, ora);
            },
            0x1e => {
                indexed_abs_x_modify(state, asl);
            },
            0x1f => {
                indexed_abs_x_modify(state, slo);
            },
            0x20 => {
                jsr(state);
            },
            0x21 => {
                indexed_indirect_read(state, and_op);
            },
            0x22 => {
                stp(state);
            },
            0x23 => {
                indexed_indirect_modify(state, rla);
            },
            0x24 => {
                zero_page_read(state, bit);
            },
            0x25 => {
                zero_page_read(state, and_op);
            },
            0x26 => {
                zero_page_modify(state, rol);
            },
            0x27 => {
                zero_page_modify(state, rla);
            },
            0x28 => {
                plp(state);
            },
            0x29 => {
                immediate_read(state, and_op);
            },
            0x2a => {
                state.regs.A = rol(state, state.regs.A);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x2b => {
                immediate_read(state, anc);
            },
            0x2c => {
                absolute_read(state, bit);
            },
            0x2d => {
                absolute_read(state, and_op);
            },
            0x2e => {
                absolute_modify(state, rol);
            },
            0x2f => {
                absolute_modify(state, rla);
            },
            0x30 => {
                branch_relative(state, bmi);
            },
            0x31 => {
                indirect_indexed_read(state, and_op);
            },
            0x32 => {
                stp(state);
            },
            0x33 => {
                indirect_indexed_modify(state, rla);
            },
            0x34 => {
                indexed_zp_x_read(state, ign);
            },
            0x35 => {
                indexed_zp_x_read(state, and_op);
            },
            0x36 => {
                indexed_zp_x_modify(state, rol);
            },
            0x37 => {
                indexed_zp_x_modify(state, rla);
            },
            0x38 => {
                sec(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x39 => {
                indexed_abs_y_read(state, and_op);
            },
            0x3a => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x3b => {
                indexed_abs_y_modify(state, rla);
            },
            0x3c => {
                indexed_abs_x_read(state, ign);
            },
            0x3d => {
                indexed_abs_x_read(state, and_op);
            },
            0x3e => {
                indexed_abs_x_modify(state, rol);
            },
            0x3f => {
                indexed_abs_x_modify(state, rla);
            },
            0x40 => {
                rti(state);
            },
            0x41 => {
                indexed_indirect_read(state, eor);
            },
            0x42 => {
                stp(state);
            },
            0x43 => {
                indexed_indirect_modify(state, sre);
            },
            0x44 => {
                zero_page_read(state, ign);
            },
            0x45 => {
                zero_page_read(state, eor);
            },
            0x46 => {
                zero_page_modify(state, lsr);
            },
            0x47 => {
                zero_page_modify(state, sre);
            },
            0x48 => {
                pha(state);
            },
            0x49 => {
                immediate_read(state, eor);
            },
            0x4a => {
                state.regs.A = lsr(state, state.regs.A);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x4b => {
                immediate_read(state, alr);
            },
            0x4c => {
                jmp_absolute(state);
            },
            0x4d => {
                absolute_read(state, eor);
            },
            0x4e => {
                absolute_modify(state, lsr);
            },
            0x4f => {
                absolute_modify(state, sre);
            },
            0x50 => {
                branch_relative(state, bvc);
            },
            0x51 => {
                indirect_indexed_read(state, eor);
            },
            0x52 => {
                stp(state);
            },
            0x53 => {
                indirect_indexed_modify(state, sre);
            },
            0x54 => {
                indexed_zp_x_read(state, ign);
            },
            0x55 => {
                indexed_zp_x_read(state, eor);
            },
            0x56 => {
                indexed_zp_x_modify(state, lsr);
            },
            0x57 => {
                indexed_zp_x_modify(state, sre);
            },
            0x58 => {
                cli(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x59 => {
                indexed_abs_y_read(state, eor);
            },
            0x5a => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x5b => {
                indexed_abs_y_modify(state, sre);
            },
            0x5c => {
                indexed_abs_x_read(state, ign);
            },
            0x5d => {
                indexed_abs_x_read(state, eor);
            },
            0x5e => {
                indexed_abs_x_modify(state, lsr);
            },
            0x5f => {
                indexed_abs_x_modify(state, sre);
            },
            0x60 => {
                rts(state);
            },
            0x61 => {
                indexed_indirect_read(state, adc);
            },
            0x62 => {
                stp(state);
            },
            0x63 => {
                indexed_indirect_modify(state, rra);
            },
            0x64 => {
                zero_page_read(state, ign);
            },
            0x65 => {
                zero_page_read(state, adc);
            },
            0x66 => {
                zero_page_modify(state, ror);
            },
            0x67 => {
                zero_page_modify(state, rra);
            },
            0x68 => {
                pla(state);
            },
            0x69 => {
                immediate_read(state, adc);
            },
            0x6a => {
                state.regs.A = ror(state, state.regs.A);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x6b => {
                immediate_read(state, arr);
            },
            0x6c => {
                jmp_through(state);
            },
            0x6d => {
                absolute_read(state, adc);
            },
            0x6e => {
                absolute_modify(state, ror);
            },
            0x6f => {
                absolute_modify(state, rra);
            },
            0x70 => {
                branch_relative(state, bvs);
            },
            0x71 => {
                indirect_indexed_read(state, adc);
            },
            0x72 => {
                stp(state);
            },
            0x73 => {
                indirect_indexed_modify(state, rra);
            },
            0x74 => {
                indexed_zp_x_read(state, ign);
            },
            0x75 => {
                indexed_zp_x_read(state, adc);
            },
            0x76 => {
                indexed_zp_x_modify(state, ror);
            },
            0x77 => {
                indexed_zp_x_modify(state, rra);
            },
            0x78 => {
                sei(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x79 => {
                indexed_abs_y_read(state, adc);
            },
            0x7a => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x7b => {
                indexed_abs_y_modify(state, rra);
            },
            0x7c => {
                indexed_abs_x_read(state, ign);
            },
            0x7d => {
                indexed_abs_x_read(state, adc);
            },
            0x7e => {
                indexed_abs_x_modify(state, ror);
            },
            0x7f => {
                indexed_abs_x_modify(state, rra);
            },
            0x80 => {
                immediate_read(state, ign);
            },
            0x81 => {
                indexed_indirect_write(state, sta);
            },
            0x82 => {
                immediate_read(state, ign);
            },
            0x83 => {
                indexed_indirect_write(state, sax);
            },
            0x84 => {
                zero_page_write(state, sty);
            },
            0x85 => {
                zero_page_write(state, sta);
            },
            0x86 => {
                zero_page_write(state, stx);
            },
            0x87 => {
                zero_page_write(state, sax);
            },
            0x88 => {
                dey(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x89 => {
                immediate_read(state, ign);
            },
            0x8a => {
                txa(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x8b => {
                // TODO XAA (it has a "usual" value, but is unpredictable)
                unreachable;
                // immediate_read(state, xaa);
            },
            0x8c => {
                absolute_write(state, sty);
            },
            0x8d => {
                absolute_write(state, sta);
            },
            0x8e => {
                absolute_write(state, stx);
            },
            0x8f => {
                absolute_write(state, sax);
            },
            0x90 => {
                branch_relative(state, bcc);
            },
            0x91 => {
                indirect_indexed_write(state, sta);
            },
            0x92 => {
                stp(state);
            },
            0x93 => {
                indirect_indexed_write(state, ahx);
            },
            0x94 => {
                indexed_zp_x_write(state, sty);
            },
            0x95 => {
                indexed_zp_x_write(state, sta);
            },
            0x96 => {
                indexed_zp_y_write(state, stx);
            },
            0x97 => {
                indexed_zp_y_write(state, sax);
            },
            0x98 => {
                tya(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x99 => {
                indexed_abs_y_write(state, sta);
            },
            0x9a => {
                txs(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0x9b => {
                indexed_abs_y_write(state, tas); // TODO double check that this is write
            },
            0x9c => {
                indexed_abs_x_write(state, shy);
            },
            0x9d => {
                indexed_abs_x_write(state, sta);
            },
            0x9e => {
                indexed_abs_y_write(state, shx);
            },
            0x9f => {
                indexed_abs_y_write(state, ahx);
            },
            0xa0 => {
                immediate_read(state, ldy);
            },
            0xa1 => {
                indexed_indirect_read(state, lda);
            },
            0xa2 => {
                immediate_read(state, ldx);
            },
            0xa3 => {
                indexed_indirect_read(state, lax);
            },
            0xa4 => {
                zero_page_read(state, ldy);
            },
            0xa5 => {
                zero_page_read(state, lda);
            },
            0xa6 => {
                zero_page_read(state, ldx);
            },
            0xa7 => {
                zero_page_read(state, lax);
            },
            0xa8 => {
                tay(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xa9 => {
                immediate_read(state, lda);
            },
            0xaa => {
                tax(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xab => {
                immediate_read(state, lax);
            },
            0xac => {
                absolute_read(state, ldy);
            },
            0xad => {
                absolute_read(state, lda);
            },
            0xae => {
                absolute_read(state, ldx);
            },
            0xaf => {
                absolute_read(state, lax);
            },
            0xb0 => {
                branch_relative(state, bcs);
            },
            0xb1 => {
                indirect_indexed_read(state, lda);
            },
            0xb2 => {
                stp(state);
            },
            0xb3 => {
                indirect_indexed_read(state, lax);
            },
            0xb4 => {
                indexed_zp_x_read(state, ldy);
            },
            0xb5 => {
                indexed_zp_x_read(state, lda);
            },
            0xb6 => {
                indexed_zp_y_read(state, ldx);
            },
            0xb7 => {
                indexed_zp_y_read(state, lax);
            },
            0xb8 => {
                clv(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xb9 => {
                indexed_abs_y_read(state, lda);
            },
            0xba => {
                tsx(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xbb => {
                indexed_abs_y_read(state, las);
            },
            0xbc => {
                indexed_abs_x_read(state, ldy);
            },
            0xbd => {
                indexed_abs_x_read(state, lda);
            },
            0xbe => {
                indexed_abs_y_read(state, ldx);
            },
            0xbf => {
                indexed_abs_y_read(state, lax);
            },
            0xc0 => {
                immediate_read(state, cpy);
            },
            0xc1 => {
                indexed_indirect_read(state, cmp);
            },
            0xc2 => {
                immediate_read(state, ign);
            },
            0xc3 => {
                // TODO implement DCP
                // indexed_indirect_modify(state, dcp);
                unreachable;
            },
            0xc4 => {
                zero_page_read(state, cpy);
            },
            0xc5 => {
                zero_page_read(state, cmp);
            },
            0xc6 => {
                zero_page_modify(state, dec);
            },
            0xc7 => {
                // TODO implement DCP
                // zero_page_modify(state, dcp);
                unreachable;
            },
            0xc8 => {
                iny(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xc9 => {
                immediate_read(state, cmp);
            },
            0xca => {
                dex(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xcb => {
                // TODO implement AXS
                // immediate_read(state, axs);
                unreachable;
            },
            0xcc => {
                absolute_read(state, cpy);
            },
            0xcd => {
                absolute_read(state, cmp);
            },
            0xce => {
                absolute_modify(state, dec);
            },
            0xcf => {
                // TODO implement DCP
                // absolute_modify(state, dcp);
                unreachable;
            },
            0xd0 => {
                branch_relative(state, bne);
            },
            0xd1 => {
                indirect_indexed_read(state, cmp);
            },
            0xd2 => {
                stp(state);
            },
            0xd3 => {
                // TODO implement DCP
                // indirect_indexed_modify(state, dcp);
                unreachable;
            },
            0xd4 => {
                indexed_zp_x_read(state, ign);
            },
            0xd5 => {
                indexed_zp_x_read(state, cmp);
            },
            0xd6 => {
                indexed_zp_x_modify(state, dec);
            },
            0xd7 => {
                // TODO implement DCP
                // indexed_zp_x_modify(state, dcp);
                unreachable;
            },
            0xd8 => {
                cld(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xd9 => {
                indexed_abs_y_read(state, cmp);
            },
            0xda => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xdb => {
                // TODO implement DCP
                // indexed_abs_y_modify(state, dcp);
                unreachable;
            },
            0xdc => {
                indexed_abs_x_read(state, ign);
            },
            0xdd => {
                indexed_abs_x_read(state, cmp);
            },
            0xde => {
                indexed_abs_x_modify(state, dec);
            },
            0xdf => {
                // TODO implement DCP
                // indexed_abs_x_modify(state, dcp);
                unreachable;
            },
            0xe0 => {
                immediate_read(state, cpx);
            },
            0xe1 => {
                indexed_indirect_read(state, sbc);
            },
            0xe2 => {
                immediate_read(state, ign);
            },
            0xe3 => {
                indexed_indirect_modify(state, isc);
            },
            0xe4 => {
                zero_page_read(state, cpx);
            },
            0xe5 => {
                zero_page_read(state, sbc);
            },
            0xe6 => {
                zero_page_modify(state, inc);
            },
            0xe7 => {
                zero_page_modify(state, isc);
            },
            0xe8 => {
                inx(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xe9 => {
                immediate_read(state, sbc);
            },
            0xea => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xeb => {
                immediate_read(state, sbc);
            },
            0xec => {
                absolute_read(state, cpx);
            },
            0xed => {
                absolute_read(state, sbc);
            },
            0xee => {
                absolute_modify(state, inc);
            },
            0xef => {
                absolute_modify(state, isc);
            },
            0xf0 => {
                branch_relative(state, beq);
            },
            0xf1 => {
                indirect_indexed_read(state, sbc);
            },
            0xf2 => {
                stp(state);
            },
            0xf3 => {
                indirect_indexed_modify(state, isc);
            },
            0xf4 => {
                indexed_zp_x_read(state, ign);
            },
            0xf5 => {
                indexed_zp_x_read(state, sbc);
            },
            0xf6 => {
                indexed_zp_x_modify(state, inc);
            },
            0xf7 => {
                indexed_zp_x_modify(state, isc);
            },
            0xf8 => {
                sed(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xf9 => {
                indexed_abs_y_read(state, sbc);
            },
            0xfa => {
                nop(state);
                _ = read_memory(state, state.regs.PC); // Waste a cycle reading the PC
            },
            0xfb => {
                indexed_abs_y_modify(state, isc);
            },
            0xfc => {
                indexed_abs_x_read(state, ign);
            },
            0xfd => {
                indexed_abs_x_read(state, sbc);
            },
            0xfe => {
                indexed_abs_x_modify(state, inc);
            },
            0xff => {
                indexed_abs_x_modify(state, isc);
            },
        }
    }
}
