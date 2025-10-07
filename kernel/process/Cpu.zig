const param = @import("../param.zig");
const riscv = @import("../riscv.zig");
const Context = @import("context.zig").Context;
const Process = @import("Process.zig");

// Per-CPU state.
proc: ?*Process, // The process running on this cpu, or null.
context: Context, // swtch() here to enter scheduler().
interrupt: struct {
    nested_counter: u32, // Depth of push_off() nesting.
    is_enabled: bool, // Were interrupts enabled before push_off()?
},

var cpus: [param.n_cpu]Self = [_]Self{Self{
    .proc = null,
    .context = undefined,
    .interrupt = .{
        .nested_counter = 0,
        .is_enabled = false,
    },
}} ** param.n_cpu; // container level variable

const Self = @This();

pub fn id() u64 {
    return riscv.tp.read();
}

pub fn current() *Self {
    return &cpus[Self.id()];
}
