const uart = @import("uart.zig");

const backspace = 0x100;

///send one character to the uart.
///called by printf(), and to echo input characters,
///but not from write().
pub fn putChar(char: u8) void {
    if (char == backspace) {
        uart.putCharSync(8); // \b
        uart.putCharSync(' ');
        uart.putCharSync(8); // \b
    } else {
        uart.putCharSync(char);
    }
}

pub fn init() void {
    uart.init();
}
