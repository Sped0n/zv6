const std = @import("std");

const Spinlock = @import("../lock/spinlock.zig");
const memlayout = @import("../memlayout.zig");
const printf = @import("../printf.zig");
const Process = @import("../process/process.zig");
const console = @import("console.zig");

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

inline fn writeReg(offset: u64, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(memlayout.uart0 + offset);
    ptr.* = value;
}

inline fn readReg(offset: u64) u8 {
    const ptr: *volatile u8 = @ptrFromInt(memlayout.uart0 + offset);
    return ptr.*;
}

const tx_buffer_size = 32;

var tx_lock: Spinlock = undefined;
var tx_buffer: [tx_buffer_size]u8 = [_]u8{0} ** 32;
var tx_w: u64 = 0;
var tx_r: u64 = 0;

pub fn init() void {
    // disable interrupts.
    writeReg(
        @as(u64, ier),
        @as(u8, 0x00),
    );

    // special mode to set baud rate.
    writeReg(
        @as(u64, lcr),
        lcr_baud_latch,
    );

    // LSB for baud rate of 38.4K.
    writeReg(0, @as(u8, 0x03));

    // MSB for baud rate of 38.4K.
    writeReg(1, @as(u8, 0x00));

    // leave set-baud mode,
    // and set word length to 8 bits, no parity.
    writeReg(lcr, lcr_eight_bits);

    // reset and enable fifo
    writeReg(
        @as(u64, fcr),
        fcr_fifo_enable | fcr_fifo_clear,
    );

    // enable transmit and receive interrupts.
    writeReg(
        @as(u64, ier),
        ier_tx_enable | ier_rx_enable,
    );

    Spinlock.init(&tx_lock, "uart");
}

///add a character to the output buffer and tell the
///UART to start sending if it isn't already.
///blocks if the output buffer is full.
///because it may block, it can't be called
///from interrupts; it's only suitable for use
///by write().
pub fn putChar(char: u8) void {
    tx_lock.acquire();
    defer tx_lock.release();

    printf.checkPanicked();

    while (tx_w == tx_r + tx_buffer_size) {
        // buffer is full.
        // wait for start() to open up space in the buffer.
        Process.sleep(@intFromPtr(&tx_r), &tx_lock);
    }
    tx_buffer[tx_w % tx_buffer_size] = char;
    tx_w += 1;
    start();
}

///alternate version of uartputc() that doesn't
///use interrupts, for use by kernel printf() and
///to echo characters. it spins waiting for the uart's
///output register to be empty.
pub fn putCharSync(char: u8) void {
    Spinlock.pushOff();
    defer Spinlock.popOff();

    printf.checkPanicked();

    // wait for Transmit Holding Empty to be set in LSR.
    while ((readReg(@as(u64, lsr)) & lsr_tx_idle) == 0) {}
    writeReg(@as(u64, thr), char);
}

///if the UART is idle, and a character is waiting
///in the transmit buffer, send it.
///caller must hold uart_tx_lock.
///called from both the top- and bottom-half.
pub fn start() void {
    while (true) {
        if (tx_w == tx_r) {
            // transmit buffer is empty
            _ = readReg(isr);
            return;
        }

        if ((readReg(@as(u64, lsr)) & lsr_tx_idle) == 0) {
            // the UART transmit holding register is full,
            // so we cannot give it another byte.
            // it will interrupt when it's ready for a new byte.
            return;
        }

        const char = tx_buffer[tx_r % tx_buffer_size];
        tx_r += 1;

        // maybe putChar() is waiting for space in the buffer.
        Process.wakeUp(@intFromPtr(&tx_r));

        writeReg(@as(u64, thr), char);
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

// handle a uart interrupt, raised because input has
// arrived, or the uart is ready for more output, or
// both. called from devintr().
pub fn intr() void {
    while (true) {
        if (getChar()) |char| {
            console.intr(char);
        } else {
            break;
        }
    }

    tx_lock.acquire();
    defer tx_lock.release();

    start();
}
