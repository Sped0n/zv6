const SpinLock = @import("../lock/SpinLock.zig");
const Process = @import("../process/Process.zig");
const uart = @import("uart.zig");

const backspace = 0x08;
const delete = 0x7f;

var lock: SpinLock = undefined;
const buffer_size = 128;
var buffer: [buffer_size]u8 = [_]u8{0} ** buffer_size;
var read_index: u32 = 0;
var write_index: u32 = 0;
var edit_index: u32 = 0;

inline fn ctrl(x: u8) u8 {
    return x - '@';
}

///send one character to the uart.
///called by printf(), and to echo input characters,
///but not from write().
pub fn putChar(char: u8) void {
    if (char == backspace) {
        // if the user typed backspace, overwrite with a space.
        uart.putCharSync(backspace); // \b
        uart.putCharSync(' ');
        uart.putCharSync(backspace); // \b
    } else {
        uart.putCharSync(char);
    }
}

///user write()s to the console go here.
pub fn write(is_user_src: bool, src_addr: u64, n: u32) u32 {
    var i: u32 = 0;

    while (i < n) : (i += 1) {
        var char: u8 = 0;
        if (!Process.eitherCopyIn(
            @ptrCast(&char),
            is_user_src,
            src_addr + i,
            1,
        )) break;
        uart.putChar(char);
    }

    return i;
}

// user read()s from the console go here.
// copy (up to) a whole input line to dst.
// user_dist indicates whether dst is a user
// or kernel address.
pub fn read(is_user_dst: bool, dest_addr: u64, n: u32) ?u32 {
    var local_n = n;
    var local_dest_addr = dest_addr;
    var char: u8 = 0;

    lock.acquire();
    defer lock.release();

    while (local_n > 0) : ({
        local_dest_addr += 1;
        local_n -= 1;

        // a whole line has arrived, return to
        // the user-level read().
        if (char == '\n') break;
    }) {
        // wait until interrupt handler has put some
        // input into buffer.
        while (read_index == write_index) {
            const curr_proc = Process.currentOrNull();
            if (curr_proc != null and curr_proc.?.isKilled())
                return null;

            Process.sleep(@intFromPtr(&read_index), &lock);
        }

        char = buffer[read_index % buffer_size];
        read_index += 1;

        if (char == ctrl('D')) { // end-of-file
            if (local_n < n) {
                // Save ^D for next time, to make sure
                // caller gets a 0-byte result.
                read_index -= 1;
            }
            break;
        }

        // copy the input byte to the user-space buffer.
        const char_buffer = char;
        if (Process.eitherCopyOut(
            is_user_dst,
            dest_addr,
            @ptrCast(&char_buffer),
            1,
        )) break;
    }

    return n - local_n;
}

pub fn intr(char: u8) void {
    lock.acquire();
    defer lock.release();

    switch (char) {
        backspace, delete => {
            if (edit_index != write_index) {
                edit_index -= 1;
                putChar(backspace);
            }
        },
        else => elseBlk: {
            if (char == 0 or (edit_index - read_index) > buffer_size)
                break :elseBlk;

            const local_char: u8 = if (char == '\r') '\n' else char;

            // echo back to the user
            putChar(local_char);

            // store for consumption by read().
            buffer[edit_index % buffer_size] = local_char;
            edit_index += 1;

            if (local_char != '\n' and local_char != ctrl(
                'D',
            ) and (edit_index - read_index) != buffer_size)
                break :elseBlk;

            // wake up consoleread() if a whole line (or end-of-file)
            // has arrived.
            write_index = read_index;
            Process.wakeUp(@intFromPtr(&read_index));
        },
    }
}

pub fn init() void {
    lock.init("cons");
    uart.init();

    // TODO: devsw
}
