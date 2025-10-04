const std = @import("std");
const mem = std.mem;

const fs = @import("../fs/fs.zig");
const kmem = @import("../memory/kmem.zig");
const vm = @import("../memory/vm.zig");
const param = @import("../param.zig");
const riscv = @import("../riscv.zig");
const utils = @import("../utils.zig");
const Process = @import("Process.zig");

const elf_magic = 0x464C457F;
const ElfHeader = extern struct {
    magic: u32,
    elf: [12]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    program_header_offset: u64,
    section_header_offset: u64,
    flags: u32,
    elf_header_size: u16,
    program_header_entry_size: u16,
    program_header_num: u16,
    section_header_entry_size: u16,
    section_header_num: u16,
    section_header_string_name_index: u16,
};

const ProgramHeaderType = enum(u32) {
    load = 1,
};
const ProgramHeaderFlag = enum(u32) {
    exec = 1,
    write = 2,
    read = 4,
};
pub const SegmentHeader = extern struct {
    type: ProgramHeaderType,
    flags: u32,
    offset: u64,
    virt_addr: u64,
    phy_addr: u64,
    file_size: u64,
    mem_size: u64,
    _align: u64,
};

pub const Error = error{
    ElfHeaderReadFailed,
    MagicMismatch,
    ProgramHeaderReadFailed,
    ProgHdrTypeMismatch,
    MemSizeLessThanFileSize,
    AddressOverflow,
    AddressNotAligned,
    StackOverflow,
    LoadSegReadFailed,
};

/// Load a program segment into pagetable at virtual address va.
/// va must be page-aligned
/// and the pages from va to va+sz must already be mapped.
/// Returns 0 on success, -1 on failure.
fn loadSegment(
    page_table: riscv.PageTable,
    virt_addr: u64,
    inode: *fs.Inode,
    offset: u32,
    size: u32,
) !void {
    var n_read: u32 = 0;
    while (n_read < size) : (n_read += riscv.pg_size) {
        const phy_addr = vm.walkAddr(
            page_table,
            virt_addr + n_read,
        ) catch unreachable;
        const step: u32 = @min(size - n_read, riscv.pg_size);
        if (try inode.read(
            false,
            phy_addr,
            offset + n_read,
            step,
        ) != step) return Error.LoadSegReadFailed;
    }
}

inline fn permFromFlags(flags: u32) u64 {
    var perm: u64 = 0;
    if (flags & @intFromEnum(ProgramHeaderFlag.exec) != 0) {
        perm = @intFromEnum(riscv.PteFlag.x);
    }
    if (flags & @intFromEnum(ProgramHeaderFlag.write) != 0) {
        perm |= @intFromEnum(riscv.PteFlag.w);
    }
    return perm;
}

pub fn exec(_path: []const u8, argv: []const kmem.Page) !u64 {
    var size: u64 = 0;

    var new_page_table: ?riscv.PageTable = null;
    errdefer {
        // If we error anywhere before committing, free the new page table
        // with whatever `size` we have allocated so far.
        if (new_page_table) |pt| {
            Process.freePageTable(pt, size);
        }
    }

    var elf_hdr: ElfHeader = undefined;

    // FS scope: begin journaled op, open + lock inode, read ELF, create page table,
    // load segments, and then release inode and end log.
    {
        fs.journal.batch.begin();
        defer fs.journal.batch.end();

        var inode = try fs.path.toInode(_path);
        inode.lock();
        defer inode.unlockPut();

        // Read ELF header.
        const n = try inode.read(
            false,
            @intFromPtr(&elf_hdr),
            0,
            @sizeOf(ElfHeader),
        );
        if (n != @sizeOf(ElfHeader)) return Error.ElfHeaderReadFailed;

        if (elf_hdr.magic != elf_magic) return Error.MagicMismatch;

        // Create a new user page table for the image we are about to load.
        var proc = Process.current() catch @panic(
            "current proc is null",
        );
        new_page_table = try proc.createPageTable();

        // Load program segments
        var offset: u64 = elf_hdr.program_header_offset;
        for (0..elf_hdr.program_header_num) |_| {
            var header: SegmentHeader = undefined;

            if (try inode.read(
                false,
                @intFromPtr(&header),
                @intCast(offset),
                @sizeOf(SegmentHeader),
            ) != @sizeOf(SegmentHeader)) return Error.ProgramHeaderReadFailed;
            offset += @sizeOf(SegmentHeader);

            // Only care about PT_LOAD
            if (header.type != ProgramHeaderType.load) continue;

            // Validate the segment.
            if (header.mem_size < header.file_size)
                return Error.MemSizeLessThanFileSize;
            if (header.virt_addr + header.mem_size < header.virt_addr)
                return Error.AddressOverflow;
            if (header.virt_addr % riscv.pg_size != 0)
                return Error.AddressNotAligned;

            // Allocate address range for this segment.
            size = try vm.uvm.malloc(
                new_page_table.?,
                size,
                header.virt_addr + header.mem_size,
                permFromFlags(header.flags),
            );

            // Load the file content into memory.
            try loadSegment(
                new_page_table.?,
                header.virt_addr,
                inode,
                @intCast(header.offset),
                @intCast(header.file_size),
            );
        }
    }

    // Re-read current proc (in case the scheduler swapped us).
    var proc = Process.current() catch @panic(
        "current proc is null",
    );
    const old_size = proc.size;

    // Allocate stack: guard page + user stack.
    size = riscv.pgRoundUp(size);
    const stack_bytes = (param.user_stack + 1) // +1 guard page
        * riscv.pg_size;
    size = try vm.uvm.malloc(
        new_page_table.?,
        size,
        size + stack_bytes,
        @intFromEnum(riscv.PteFlag.w),
    );

    // Clear the guard page.
    vm.uvm.clear(new_page_table.?, size - stack_bytes);

    // Prepare user stack layout and copy argv strings.
    var sp = size;
    const stack_base = sp - param.user_stack * riscv.pg_size;

    var ustack = [_]u64{0} ** param.max_arg;
    const argc: usize = argv.len;

    for (argv, 0..) |arg, i| {
        const arg_len_with_null = (mem.indexOfScalar(
            u8,
            arg,
            0,
        ) orelse 0) + 1;

        sp -= arg_len_with_null;
        sp -= (sp % 16); // 16-byte align
        if (sp < stack_base) return Error.StackOverflow;

        try vm.uvm.copyFromKernel(
            new_page_table.?,
            sp,
            arg,
            arg_len_with_null,
        );
        ustack[i] = sp;
    }
    ustack[argc] = 0;

    // Push argv[] (array of pointers).
    const argv_array_size = (argc + 1) * @sizeOf(u64);
    sp -= argv_array_size;
    sp -= sp % 16;
    if (sp < stack_base) return Error.StackOverflow;

    try vm.uvm.copyFromKernel(
        new_page_table.?,
        sp,
        @ptrCast(&ustack),
        argv_array_size,
    );

    // a1 = argv for user main(argc, argv)
    proc.trap_frame.?.a1 = sp;

    // Save program name for debugging.
    var program_name: []const u8 = undefined;
    if (mem.lastIndexOfScalar(u8, _path, '/')) |last| {
        program_name = _path[last + 1 ..];
    } else {
        program_name = _path;
    }
    utils.safeStrCopy(&proc.name, program_name);

    // Commit to the new user image.
    const old_page_table = proc.page_table.?;
    proc.page_table = new_page_table; // becomes the process's page table
    proc.size = size;
    proc.trap_frame.?.epc = elf_hdr.entry;
    proc.trap_frame.?.sp = sp;

    // Free old page table.
    Process.freePageTable(old_page_table, old_size);

    // argc returned in a0 by the syscall machinery; we return it here.
    return @intCast(argc);
}
