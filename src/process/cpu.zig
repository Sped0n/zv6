const param = @import("../param.zig");
const riscv = @import("../riscv.zig");
const Context = @import("context.zig").Context;
const Process = @import("process.zig");

// Per-CPU state.
proc: ?*Process, // The process running on this cpu, or null.
context: Context, // swtch() here to enter scheduler().
noff: u32, // Depth of push_off() nesting.
intr_enable: bool, // Were interrupts enabled before push_off()?

var cpus: [param.n_cpu]Self = undefined; // container level variable

const Self = @This();

pub fn id() u64 {
    return riscv.tp.read();
}

pub fn current() *Self {
    return &cpus[Self.id()];
}
