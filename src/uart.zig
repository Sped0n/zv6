const std = @import("std");

const memlayout = @import("memlayout.zig");
const Spinlock = @import("spinlock.zig");
const misc = @import("misc.zig");

// the UART control registers.
// some have different meanings for
// read vs write.
// see http://byterunner.com/16550.html
const rhr: u8 = 0; // Receive Holding Register
const thr: u8 = 0; // Transmit Holding Register
const ier: u8 = 1; // Interrupt Enable Register
const ier_rx_enable: u8 = 1 << 0;
const ier_tx_enable: u8 = 1 << 1;
const fcr: u8 = 2; // FIFO Control Register
const fcr_fifo_enable: u8 = 1 << 0;
const fcr_fifo_clear: u8 = 3 << 1;
const isr: u8 = 2; // Interrupt Status Register
const lcr: u8 = 3; // Line Control Register
const lcr_eight_bits: u8 = 3 << 0;
const lcr_baud_latch: u8 = 1 << 7;
const lsr: u8 = 5; // Line Status Register
const lsr_rx_ready: u8 = 1 << 0;
const lsr_tx_idle: u8 = 1 << 5;

inline fn writeReg(offset: usize, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(memlayout.uart0 + offset);
    ptr.* = value;
}

inline fn readReg(offset: usize) u8 {
    const ptr: *volatile u8 = @ptrFromInt(memlayout.uart0 + offset);
    return ptr.*;
}

const uart_tx_buffer_size = 32;

tx_lock: Spinlock,
tx_buffer: [uart_tx_buffer_size]u8,
tx_w: u64,
tx_r: u64,

const Self = @This();

pub fn init(self: *Self) void {
    // disable interrupts.
    writeReg(
        @as(usize, ier),
        @as(u8, 0x00),
    );

    // special mode to set baud rate.
    writeReg(
        @as(usize, lcr),
        lcr_baud_latch,
    );

    // LSB for baud rate of 38.4K.
    writeReg(0, @as(u8, 0x03));

    // MSB for baud rate of 38.4K.
    writeReg(1, @as(u8, 0x00));

    // leave set-baud mode,
    // and set word length to 8 bits, no parity
    writeReg(
        @as(usize, fcr),
        fcr_fifo_enable | fcr_fifo_clear,
    );

    Spinlock.init(&self.*.tx_lock, "uart");
    self.*.tx_buffer = [_]u8{0} ** 32;
    self.*.tx_w = 0;
    self.*.tx_r = 0;
}

///add a character to the output buffer and tell the
///UART to start sending if it isn't already.
///blocks if the output buffer is full.
///because it may block, it can't be called
///from interrupts; it's only suitable for use
///by write().
pub fn putChar(self: *Self, char: u8) void {
    self.tx_lock.acquire();
    defer self.tx_lock.acquire();

    // TODO: panicked detection
    while (self.uart_tx_w == self.uart_tx_r + uart_tx_buffer_size) {
        // TODO: sleep
    }
    self.tx_buffer[self.uart_tx_w % uart_tx_buffer_size] = char;
    self.tx_w += 1;
    self.uartStart();
}

///alternate version of uartputc() that doesn't
///use interrupts, for use by kernel printf() and
///to echo characters. it spins waiting for the uart's
///output register to be empty.
pub fn putCharSync(char: u8) void {
    misc.pushOff();
    defer misc.popOff();

    // TODO: panicked detection

    // wait for Transmit Holding Empty to be set in LSR.
    while ((readReg(@as(usize, lsr)) & lsr_tx_idle) == 0) {}
    writeReg(@as(usize, thr), char);
}

///if the UART is idle, and a character is waiting
///in the transmit buffer, send it.
///caller must hold uart_tx_lock.
///called from both the top- and bottom-half.
pub fn uartStart(self: *Self) void {
    while (true) {
        if (self.tx_w == self.tx_r) {
            // transmit buffer is empty
            _ = readReg(isr);
            return;
        }

        if ((readReg(@as(usize, lsr)) & lsr_tx_idle) == 0) {
            // the UART transmit holding register is full,
            // so we cannot give it another byte.
            // it will interrupt when it's ready for a new byte.
            return;
        }

        const char = self.tx_buffer[self.tx_r % uart_tx_buffer_size];
        self.tx_r += 1;

        // maybe putChar() is waiting for space in the buffer.
        // TODO: wakeup

        writeReg(@as(usize, thr), char);
    }
}

///read one input character from the UART.
///return null if none is waiting.
pub fn getChar() ?u8 {
    if (readReg(lsr) & 0x01 != 0) {
        return readReg(rhr);
    } else {
        return null;
    }
}

pub fn dumbPrint(str: []const u8) void {
    for (str) |c| {
        putCharSync(c);
    }
    putCharSync('\n');
}

pub fn dumbPanic(str: []const u8) void {
    dumbPrint(str);
    while (true) {}
}

pub fn dumbAssert(cond: bool, info: []const u8) void {
    if (cond) return;
    const assert_str: []const u8 = "assert failed: ";
    for (assert_str) |c| {
        putCharSync(c);
    }
    dumbPanic(info);
}
