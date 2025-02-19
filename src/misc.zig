const riscv = @import("riscv.zig");
const Cpu = @import("proc.zig").Cpu;

///push_off/pop_off are like intr_off()/intr_on() except that they are matched:
///it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
///are initially off, then push_off, pop_off leaves them off.
pub fn pushOff() void {
    const old = riscv.intrGet();

    riscv.intrOff();
    if (Cpu.myCpu().noff == 0) Cpu.myCpu().intena = old;
    Cpu.myCpu().noff += 1;
}

///push_off/pop_off are like intr_off()/intr_on() except that they are matched:
///it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
///are initially off, then push_off, pop_off leaves them off.
pub fn popOff() void {
    var c = Cpu.myCpu();
    if (riscv.intrGet()) {} // TODO: panic
    if (c.noff < 1) {} // TODO: panic
    c.noff -= 1;
    if (c.noff == 0 and c.intena) riscv.intrOn();
}
