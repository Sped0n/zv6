// Factories -------------------------------------------------------------------

pub fn Register(comptime name: []const u8) type {
    return struct {
        ///Read the register value
        pub inline fn read() u64 {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> u64),
            );
        }

        ///Write a value to the register
        pub inline fn write(value: u64) void {
            asm volatile ("csrw " ++ name ++ ", a0"
                :
                : [value] "{a0}" (value),
            );
        }
    };
}

pub fn ReadOnlyRegister(comptime name: []const u8) type {
    return struct {
        ///Read the register value
        pub inline fn read() u64 {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> u64),
            );
        }
    };
}

pub fn WriteOnlyRegister(comptime name: []const u8) type {
    return struct {
        ///Write a value to the register
        pub inline fn write(value: u64) void {
            asm volatile ("csrw " ++ name ++ ", a0"
                :
                : [value] "{a0}" (value),
            );
        }
    };
}

// mhartid ---------------------------------------------------------------------

///hartid (cpu core id)
pub const mhartid = ReadOnlyRegister("mhartid");

// mstatus ---------------------------------------------------------------------

///Machine Status Register, mstatus
pub const MStatusValue = enum(u64) {
    mpp_machine_or_mask = 3 << 11,
    mpp_supervisor = 1 << 11,
    mpp_user = 0 << 11,
    mie = 1 << 3, // machine-mode interrupt enable.
};

///Machine Status Register, mstatus
pub const mstatus = Register("mstatus");

// mepc ------------------------------------------------------------------------

///Writer Machine Execption Program Counter, mepc
///
///mepc holds the instruction address to which a return
///from exception will go
pub const mepc = WriteOnlyRegister("mepc");

// sstatus ----------------------------------------------------------------------

///Supervisor Status Register, sstatus
pub const SStatusValue = enum(u64) {
    spp = 1 << 8, // Previous mode, 1=Supervisor, 0=User
    spie = 1 << 5, // Supervisor Previous Interrupt Enable
    upie = 1 << 4, // User Previous Interrupt Enable
    sie = 1 << 1, // Supervisor Interrupt Enable
    uie = 1 << 0, // User Interrupt Enable
};

///Supervisor Status Register, sstatus
pub const sstatus = Register("sstatus");

// sip -------------------------------------------------------------------------

///Read Supervisor Interrupt Pending, sip
pub const sip = Register("sip");

// sie -------------------------------------------------------------------------

///Supervisor Interrupt Enable, sie
pub const SieValue = enum(u64) {
    seie = 1 << 9, // external
    stie = 1 << 5, // timer
    ssie = 1 << 1, // software
};

///Supervisor Interrupt Enable, sie
pub const sie = Register("sie");

// mie -------------------------------------------------------------------------

///Machine-mode Interrupt Enable, mie
pub const MieValue = enum(u64) {
    meie = 1 << 11, // external
    mtie = 1 << 7, // timer
    msie = 1 << 3, // software
};

///Machine-mode Interrupt Enable, mie
pub const mie = Register("mie");

// sepc ------------------------------------------------------------------------

///Supervisor Exception Program Counter, sepc
///
///sepc holds the instruction address to which a
///return from exception will go.
pub const sepc = Register("sepc");

// medeleg ----------------------------------------------------------------------

///Machine Exception Delegation, medeleg
pub const medeleg = Register("medeleg");

// mideleg ----------------------------------------------------------------------

///Machine Interrupt Delegation, mideleg
pub const mideleg = Register("mideleg");

// stvec -----------------------------------------------------------------------

///Supervisor Trap-Vector Base Address, stvec
///
///Low two bits are mode.
pub const stvec = Register("stvec");

// mtvec -----------------------------------------------------------------------

///Machine-mode interrupt vector, mtvec
pub const mtvec = Register("mtvec");

// stimecmp --------------------------------------------------------------------

///Supervisor Timer Comparison Register, stimecmp
pub const stimecmp = Register("0x14d");

// menvcfg ---------------------------------------------------------------------

///Machine Environment Configuration Register, menvcfg
pub const menvcfg = Register("0x30a");

// pmpcfg0 and pmpaddr0 --------------------------------------------------------

///Physical Memory Protection Config, pmpcfg0
pub const pmpcfg0 = WriteOnlyRegister("pmpcfg0");

///Physical Memory Protection Address. pmpaddr0
pub const pmpaddr0 = WriteOnlyRegister("pmpaddr0");

// satp ------------------------------------------------------------------------

// use riscv's sv39 page table scheme.
const satp_sv39 = @as(u64, 8) << 60;

///Make a Supervisor Address Translation and Protection table, satp
pub inline fn makeSatp(pagetable: PageTable) u64 {
    return satp_sv39 | (@intFromPtr(pagetable) >> 12);
}

///Supervisor Address Translation and Protection table, satp
///
///satp holds the address of the page table.
pub const satp = Register("satp");

// mscratch --------------------------------------------------------------------

pub const mscratch = Register("mscratch");

// sscratch --------------------------------------------------------------------

pub const sscratch = Register("sscratch");

// scause and stval ------------------------------------------------------------

pub const scause = ReadOnlyRegister("scause");

pub const stval = ReadOnlyRegister("stval");

// mcounteren ------------------------------------------------------------------

///Machine-mode Counter-Enable, mcounteren
pub const mcounteren = Register("mcounteren");

// time ------------------------------------------------------------------------

//Machine-mode cycle counter, time
pub const time = ReadOnlyRegister("time");

// interrupt control -----------------------------------------------------------

///Enable device interrupts
pub inline fn intrOn() void {
    sstatus.write(sstatus.read() | @intFromEnum(SStatusValue.sie));
}

///Disable device interrupts
pub inline fn intrOff() void {
    sstatus.write(sstatus.read() & ~@intFromEnum(SStatusValue.sie));
}

///Check if device interrupts are enabled
pub inline fn intrGet() bool {
    return (sstatus.read() & @intFromEnum(SStatusValue.sie)) != 0;
}

// sp, tp and ra ---------------------------------------------------------------

pub const sp = struct {
    pub inline fn read() u64 {
        return asm volatile ("mv a0, sp"
            : [ret] "={a0}" (-> u64),
        );
    }
};

///tp, the thread pointer, which xv6 uses to hold this
///core's hartid (core number), the index into cpus[].
pub const tp = struct {
    ///Read the register value
    pub inline fn read() u64 {
        return asm volatile ("mv a0, tp"
            : [ret] "={a0}" (-> u64),
        );
    }

    ///Write a value to the register
    pub inline fn write(value: u64) void {
        asm volatile ("mv tp, a0"
            :
            : [value] "{a0}" (value),
        );
    }
};

pub const ra = struct {
    pub inline fn read() u64 {
        return asm volatile ("mv a0, ra"
            : [ret] "={a0}" (-> u64),
        );
    }
};

// Misc ------------------------------------------------------------------------

// flush the TLB.
pub inline fn sfenceVma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

// Page table ------------------------------------------------------------------

///Page Table Entry
pub const Pte = u64;
pub const PageTable = *[512]Pte; // 512 PTEs

pub const pg_size = 4096; // bytes per page
pub const pg_shift = 12; // bits of offset within a page
pub inline fn pgRoundUp(sz: u64) u64 {
    return ((sz) + pg_size - 1) & ~@as(u64, pg_size - 1);
}
pub inline fn pgRoundDown(sz: u64) u64 {
    return ((sz)) & ~@as(u64, pg_size - 1);
}

///Page Table Entry flags
pub const PteFlag = enum(u64) {
    v = 1 << 0, // valid
    r = 1 << 1,
    w = 1 << 2,
    x = 1 << 3,
    u = 1 << 4, // user can access
};

///Physical Address to Page Table Entry
pub inline fn pa2Pte(pa: u64) Pte {
    return @as(u64, pa >> 12) << 10;
}
///Page Table Entry to Physical Address
pub inline fn pte2Pa(pte: Pte) u64 {
    return @as(u64, pte >> 10) << 12;
}
///Page Table Entry flags
pub inline fn pteFlags(pte: Pte) u64 {
    return @as(u64, pte & 0x3FF);
}

const px_mask = 0x1FF; // 9 bits

inline fn pageTableIdxShift(level: u64) u6 {
    return @intCast(pg_shift + 9 * level);
}

///Extract the three 9-bit page table indices from a virtual address.
pub inline fn pageTableIdxFromVa(level: u64, va: u64) u64 {
    return (va >> pageTableIdxShift(level)) & px_mask;
}

///one beyond the highest possible virtual address.
///MAXVA is actually one bit less than the max allowed by
///Sv39, to avoid having to sign-extend virtual addresses
///that have the high bit set.
pub const max_va: u64 = @as(u64, 1) << (9 + 9 + 9 + 12 - 1);
