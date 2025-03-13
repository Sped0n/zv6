const param = @import("../param.zig");
const panic = @import("../printf.zig").panic;
const riscv = @import("../riscv.zig");
const Context = @import("context.zig").Context;
const Cpu = @import("Cpu.zig");
const Process = @import("Process.zig");

extern fn swtch(a: *Context, b: *Context) void;

///Per-CPU process scheduler.
///Each CPU calls scheduler() after setting itself up.
///Scheduler never returns.  It loops, doing:
/// - choose a process to run.
/// - swtch to start running that process.
/// - eventually that process transfers control
///   via swtch back to the scheduler.
pub fn scheduler() void {
    const cpu = Cpu.current();

    cpu.proc = null;
    while (true) {
        // The most recent process to run may have had interrupts
        // turned off; enable them to avoid a deadlock if all
        // processes are waiting.
        riscv.intrOn();

        var found = false;
        for (0..param.n_proc) |i| {
            const proc = &Process.procs[i];
            proc.lock.acquire();
            defer proc.lock.release();

            if (proc.state == .runnable) {
                // Switch to chosen process.  It is the process's job
                // to release its lock and then reacquire it
                // before jumping back to us.
                proc.state = .running;
                cpu.proc = proc;
                swtch(&cpu.context, &proc.context);

                // Process is done running for now.
                // It should have changed its p->state before coming back.
                cpu.proc = null;
                found = true;
            }
        }

        if (!found) {
            // nothing to run; stop running on this core until an interrupt.
            riscv.intrOn();
            asm volatile ("wfi");
        }
    }
}

///Switch to scheduler.  Must hold only p->lock
///and have changed proc->state. Saves and restores
///intena because intena is a property of this
///kernel thread, not this CPU. It should
///be proc->intena and proc->noff, but that would
///break in the few places where a lock is held but
///there's no process.
pub fn sched() void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    if (!proc.lock.holding())
        panic(@src(), "proc lock not holding", .{});
    if (Cpu.current().noff != 1)
        panic(@src(), "cpu noff({d}) is not 1", .{Cpu.current().noff});
    if (proc.state == .running)
        panic(@src(), "current proc is running", .{});
    if (riscv.intrGet())
        panic(@src(), "interruptible", .{});

    const intr_enable = Cpu.current().intr_enable;
    swtch(&proc.context, &Cpu.current().context);
    Cpu.current().intr_enable = intr_enable;
}
