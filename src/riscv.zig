// mhartid ---------------------------------------------------------------------

///Read hartid (core id)
pub inline fn rMhartid() usize {
    return asm volatile ("csrr a0, mhartid"
        : [ret] "={a0}" (-> usize),
    );
}

// mstatus ---------------------------------------------------------------------

///Machine Status Register, mstatus
pub const MStatus = enum(usize) {
    mpp_machine_or_mask = 3 << 11,
    mpp_supervisor = 1 << 11,
    mpp_user = 0 << 11,
    mie = 1 << 3, // machine-mode interrupt enable.
};

///Read Machine Status Register, mstatus
pub inline fn rMstatus() usize {
    return asm volatile ("csrr a0, mstatus"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Machine Status Register, mstatus
pub inline fn wMstatus(status: usize) void {
    asm volatile ("csrw mstatus, a0"
        :
        : [status] "{a0}" (status),
    );
}

// mepc ------------------------------------------------------------------------

///Writer Machine Execption Program Counter, mepc
///
///mepc holds the instruction address to which a return
///from exception will go
pub inline fn wMepc(counter: usize) void {
    asm volatile ("csrw mepc, a0"
        :
        : [counter] "{a0}" (counter),
    );
}

// sstatus ----------------------------------------------------------------------

///Supervisor Status Register, sstatus
pub const SStatus = enum(usize) {
    spp = 1 << 8, // Previous mode, 1=Supervisor, 0=User
    spie = 1 << 5, // Supervisor Previous Interrupt Enable
    upie = 1 << 4, // User Previous Interrupt Enable
    sie = 1 << 1, // Supervisor Interrupt Enable
    uie = 1 << 0, // User Interrupt Enable
};

///Read Supervisor Status Register, sstatus
pub inline fn rSstatus() usize {
    return asm volatile ("csrr a0, sstatus"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Supervisor Status Register, sstatus
pub inline fn wSstatus(sstatus: usize) void {
    asm volatile ("csrw sstatus, a0"
        :
        : [sstatus] "{a0}" (sstatus),
    );
}

// sip -------------------------------------------------------------------------

///Read Supervisor Interrupt Pending, sip
pub inline fn rSip() usize {
    return asm volatile ("csrr a0, sip"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Supervisor Interrupt Pending, sip
pub inline fn wSip(sip: usize) void {
    asm volatile ("csrw sip, a0"
        :
        : [sip] "{a0}" (sip),
    );
}

// sie -------------------------------------------------------------------------

///Supervisor Interrupt Enable, sie
pub const Sie = enum(usize) {
    seie = 1 << 9, // external
    stie = 1 << 5, // timer
    ssie = 1 << 1, // software
};

///Supervisor Interrupt Enable, sie
pub inline fn rSie() usize {
    return asm volatile ("csrr a0, sie"
        : [ret] "={a0}" (-> usize),
    );
}

///Supervisor Interrupt Enable, sie
pub inline fn wSie(sie: usize) void {
    asm volatile ("csrw sie, a0"
        :
        : [sie] "{a0}" (sie),
    );
}

// mie -------------------------------------------------------------------------

///Machine-mode Interrupt Enable, mie
pub const Mie = enum(usize) {
    meie = 1 << 11, // external
    mtie = 1 << 7, // timer
    msie = 1 << 3, // software
};

///Machine-mode Interrupt Enable, mie
pub inline fn rMie() usize {
    return asm volatile ("csrr a0, mie"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Machine-mode Interrupt Enable, mie
pub inline fn wMie(mie: usize) void {
    asm volatile ("csrw mie, a0"
        :
        : [mie] "{a0}" (mie),
    );
}

// sepc ------------------------------------------------------------------------

///Write Supervisor Exception Program Counter, sepc
///
///sepc holds the instruction address to which a
///return from exception will go.
pub inline fn wSepc(sepc: usize) void {
    asm volatile ("csrw sepc, a0"
        :
        : [sepc] "{a0}" (sepc),
    );
}

///Read Supervisor Exception Program Counter, sepc
///
///sepc holds the instruction address to which a
///return from exception will go.
pub inline fn rSepc() usize {
    return asm volatile ("csrr a0, sepc"
        : [ret] "={a0}" (-> usize),
    );
}

// medeleg ----------------------------------------------------------------------

///Read Machine Exception Delegation, medeleg
pub inline fn rMdeleg() usize {
    return asm volatile ("csrr a0, medeleg"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Machine Exception Delegation, medeleg
pub inline fn wMedeleg(medeleg: usize) void {
    asm volatile ("csrw medeleg, a0"
        :
        : [medeleg] "{a0}" (medeleg),
    );
}

// mideleg ----------------------------------------------------------------------

///Read Machine Interrupt Delegation, mideleg
pub inline fn rMideleg() usize {
    return asm volatile ("csrr a0, mideleg"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Machine Interrupt Delegation. mideleg
pub inline fn wMideleg(mideleg: usize) void {
    asm volatile ("csrw mideleg, a0"
        :
        : [mideleg] "{a0}" (mideleg),
    );
}

// stvec -----------------------------------------------------------------------

///Write Supervisor Trap-Vector Base Address, stvec
///
///Low two bits are mode.
pub inline fn wStvec(stvec: usize) void {
    asm volatile ("csrw stvec, a0"
        :
        : [stvec] "{a0}" (stvec),
    );
}

///Read Supervisor Trap-Vector Base Address, stvec
///
///Low two bits are mode.
pub inline fn rStvec() usize {
    return asm volatile ("csrr a0, stvec"
        : [ret] "={a0}" (-> usize),
    );
}

// mtvec -----------------------------------------------------------------------

///Write Machine-mode interrupt vector
pub inline fn wMtvec(mtvec: usize) void {
    asm volatile ("csrw mtvec, a0"
        :
        : [mtvec] "{a0}" (mtvec),
    );
}

// stimecmp --------------------------------------------------------------------

///Read Supervisor Timer Comparison Register, stimecmp
pub inline fn rStimecmp() usize {
    return asm volatile ("csrr a0, 0x14d"
        : [ret] "={a0}" (-> usize),
    );
}

///Read Supervisor Timer Comparison Register, stimecmp
pub inline fn wStimecmp(stimecmp: usize) void {
    return asm volatile ("csrw 0x14d, a0"
        :
        : [stimecmp] "{a0}" (stimecmp),
    );
}

// menvcfg ---------------------------------------------------------------------

///Read Machine Environment Configuration Register, menvcfg
pub inline fn rMenvcfg() usize {
    return asm volatile ("csrr a0, 0x30a"
        : [ret] "={a0}" (-> usize),
    );
}

///Write Machine Environment Configuration Register, menvcfg
pub inline fn wMenvcfg(menvcfg: usize) void {
    return asm volatile ("csrw 0x30a, a0"
        :
        : [menvcfg] "{a0}" (menvcfg),
    );
}

// pmpcfg0 and pmpaddr0 --------------------------------------------------------

///Write Physical Memory Protection Config, pmpcfg0
pub inline fn wPmpcfg0(pmpcfg0: usize) void {
    asm volatile ("csrw pmpcfg0, a0"
        :
        : [pmpcfg0] "{a0}" (pmpcfg0),
    );
}

///Write Physical Memory Protection Address. pmpaddr0
pub inline fn wPmpaddr0(pmpaddr0: usize) void {
    asm volatile ("csrw pmpaddr0, a0"
        :
        : [pmpaddr0] "{a0}" (pmpaddr0),
    );
}

// satp ------------------------------------------------------------------------

// use riscv's sv39 page table scheme.
pub const SATP_SV39 = @as(usize, 8) << 60;

///Make a Supervisor Address Translation and Protection table, satp
pub fn makeSatp(pagetable: PageTable) usize {
    return SATP_SV39 | (@intFromPtr(pagetable) >> 12);
}

///Write Supervisor Address Translation and Protection table, satp
///
///satp holds the address of the page table.
pub inline fn wSatp(satp: usize) void {
    asm volatile ("csrw satp, a0"
        :
        : [satp] "{a0}" (satp),
    );
}

///Write Supervisor Address Translation and Protection table, satp
///
///satp holds the address of the page table.
pub inline fn rSatp() usize {
    return asm volatile ("csrr a0, satp"
        : [ret] "={a0}" (-> usize),
    );
}

// mscratch --------------------------------------------------------------------

pub inline fn wMscratch(mscratch: usize) void {
    asm volatile ("csrw mscratch, a0"
        :
        : [mscratch] "{a0}" (mscratch),
    );
}

pub inline fn rMscratch() usize {
    return asm volatile ("csrw a0, mscratch"
        : [ret] "={a0}" (-> usize),
    );
}

// sscratch --------------------------------------------------------------------

pub inline fn wSscratch(sscratch: usize) void {
    asm volatile ("csrw sscratch, a0"
        :
        : [mscratch] "{a0}" (sscratch),
    );
}

pub inline fn rSscratch() usize {
    return asm volatile ("csrw a0, sscratch"
        : [ret] "={a0}" (-> usize),
    );
}

// scause and stval ------------------------------------------------------------

///Read Supervisor Trap Cause
pub inline fn rScause() usize {
    return asm volatile ("csrr a0, scause"
        : [ret] "={a0}" (-> usize),
    );
}

///Read Supervisor Trap Value
pub inline fn rStval() usize {
    return asm volatile ("csrr a0, stval"
        : [ret] "={a0}" (-> usize),
    );
}

// mcounteren ------------------------------------------------------------------

///Write Machine-mode Counter-Enable
pub inline fn wMcounteren(mcounteren: usize) void {
    asm volatile ("csrw mcounteren, a0"
        :
        : [mcounteren] "{a0}" (mcounteren),
    );
}

///Read Machine-mode Counter-Enable
pub inline fn rMcounteren() usize {
    return asm volatile ("csrr a0, mcounteren"
        : [ret] "={a0}" (-> usize),
    );
}

// time ------------------------------------------------------------------------

//Read machine-mode cycle counter, time
pub inline fn rTime() usize {
    return asm volatile ("csrr a0, time"
        : [ret] "={a0}" (-> usize),
    );
}

// interrupt control -----------------------------------------------------------

///Enable device interrupts
pub inline fn intrOn() void {
    wSstatus(rSstatus() | @intFromEnum(SStatus.sie));
}

///Disable device interrupts
pub inline fn intrOff() void {
    wSstatus(rSstatus() & ~@intFromEnum(SStatus.sie));
}

///Check if device interrupts are enabled
pub inline fn intrGet() bool {
    return (rSstatus() & @intFromEnum(SStatus.sie)) != 0;
}

// sp, tp and ra ---------------------------------------------------------------

pub inline fn rSp() usize {
    return asm volatile ("mv a0, sp"
        : [ret] "={a0}" (-> usize),
    );
}

///Read tp, the thread pointer, which xv6 uses to hold this
///core's hartid (core number), the index into cpus[].
pub inline fn rTp() usize {
    return asm volatile ("mv a0, tp"
        : [ret] "={a0}" (-> usize),
    );
}

///Write tp, the thread pointer, which xv6 uses to hold this
///core's hartid (core number), the index into cpus[].
pub inline fn wTp(tp: usize) void {
    asm volatile ("mv tp, a0"
        :
        : [tp] "{a0}" (tp),
    );
}

pub inline fn rRa() usize {
    return asm volatile ("mv a0, ra"
        : [ret] "={a0}" (-> usize),
    );
}

// Misc ------------------------------------------------------------------------

// flush the TLB.
pub inline fn sfenceVma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

// Page table ------------------------------------------------------------------

///Page Table Entry
pub const Pte = usize;
pub const PageTable = *[512]Pte; // 512 PTEs

pub const pg_size = 4096; // bytes per page
pub const pg_shift = 12; // bits of offset within a page
pub inline fn pgRoundUp(sz: usize) usize {
    return ((sz) + pg_size - 1) & ~@as(usize, pg_size - 1);
}
pub inline fn pgRoundDown(sz: usize) usize {
    return ((sz)) & ~@as(usize, pg_size - 1);
}

///Page Table Entry flags
pub const PteFlag = enum(usize) {
    v = 1 << 0, // valid
    r = 1 << 1,
    w = 1 << 2,
    x = 1 << 3,
    u = 1 << 4, // user can access
};

// shift a physical address to the right place for a PTE.

///Physical Address to Page Table Entry
pub inline fn pa2Pte(pa: usize) Pte {
    return @as(usize, pa >> 12) << 10;
}
///Page Table Entry to Physical Address
pub inline fn pte2Pa(pte: Pte) usize {
    return @as(usize, pte >> 10) << 12;
}
///Read Page Table Entry flags
pub inline fn rPteFlags(pte: usize) usize {
    return @as(usize, pte & 0x3FF);
}

const px_mask = 0x1FF; // 9 bits
inline fn pxShift(level: usize) u6 {
    return @intCast(pg_shift + 9 * level);
}
///Extract the three 9-bit page table indices from a virtual address.
pub inline fn px(level: usize, va: usize) usize {
    return (va >> pxShift(level)) & px_mask;
}

///one beyond the highest possible virtual address.
///MAXVA is actually one bit less than the max allowed by
///Sv39, to avoid having to sign-extend virtual addresses
///that have the high bit set.
pub const maxva: usize = @as(usize, 1) << (9 + 9 + 9 + 12 - 1);
