const std = @import("std");
const mem = std.mem;

const riscv = @import("../riscv.zig");
const Inode = @import("../fs/Inode.zig");
const vm = @import("../memory/vm.zig");
const log = @import("../fs/log.zig");
const param = @import("../param.zig");
const path = @import("../fs/path.zig");
const Process = @import("Process.zig");
const panic = @import("../printf.zig").panic;
const misc = @import("../misc.zig");

pub const elf_magic = 0x464C457F;

pub const ElfHeader = extern struct {
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

pub const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    virt_addr: u64,
    phy_addr: u64,
    file_size: u64,
    mem_size: u64,
    _align: u64,
};

const ProgramHeaderType = struct {
    var load: u32 = 1;
};

const ProgramHeaderFlag = enum(u32) {
    exec = 1,
    write = 2,
    read = 4,
};

pub const Error = error{
    MagicMismatch,
    ProgHdrTypeMismatch,
    MemSizeLessThanFileSize,
    AddressOverflow,
    AddressNotAligned,
    StackOverflow,
};

///Load a program segment into pagetable at virtual address va.
///va must be page-aligned
///and the pages from va to va+sz must already be mapped.
///Returns 0 on success, -1 on failure.
fn loadSeg(
    page_table: riscv.PageTable,
    virt_addr: u64,
    inode_ptr: *Inode,
    offset: u32,
    size: u32,
) !void {
    var i: u32 = 0;
    while (i < size) : (i += riscv.pg_size) {
        const phy_addr = vm.walkAddr(
            page_table,
            virt_addr + i,
        ) catch |e| {
            panic(
                @src(),
                "address should exist, but walkAddr failed with {s}",
                .{@errorName(e)},
            );
        };
        const n: u32 = @min(size - i, riscv.pg_size);
        try inode_ptr.read(
            false,
            phy_addr,
            offset + i,
            n,
        );
    }
}

fn flagsToPerm(flags: u32) u64 {
    if (flags & 0x1 != 0) return riscv.PteFlag.x;
    if (flags & 0x2 != 0) return riscv.PteFlag.w;
    return 0;
}

pub fn exec(_path: []const u8, argv: []const [*c]u8) !u64 {
    var size: u64 = 0;
    var inode_ptr: ?*Inode = null;
    var page_table: ?riscv.PageTable = null;

    var _error: anyerror = undefined;
    ok_blk: {
        var elf_hdr: ElfHeader = undefined;
        var prog_hdr: ProgramHeader = undefined;
        var proc = Process.current() catch panic(
            @src(),
            "current proc is null",
            .{},
        );

        log.beginOp();

        inode_ptr = try path.namei(_path);
        inode_ptr.?.lock();

        // Check ELF header.
        inode_ptr.?.read(
            false,
            @intFromPtr(&elf_hdr),
            0,
            @sizeOf(ElfHeader),
        ) catch |e| {
            _error = e;
            break :ok_blk;
        };

        if (elf_hdr.magic != elf_magic) {
            _error = Error.MagicMismatch;
            break :ok_blk;
        }

        // Create page table.
        page_table = proc.createPageTable() catch |e| {
            _error = e;
            break :ok_blk;
        };

        // Load program into memory.
        var i: u16 = 0;
        var offset = elf_hdr.program_header_offset;
        const prog_hdr_size = @sizeOf(ProgramHeader);
        while (i < elf_hdr.program_header_num) : ({
            i += 1;
            offset += prog_hdr_size;
        }) {
            // Read program header
            inode_ptr.?.read(
                false,
                @intFromPtr(&prog_hdr),
                offset,
                prog_hdr_size,
            ) catch |e| {
                _error = e;
                break :ok_blk;
            };

            // Check if it is load segment.
            if (prog_hdr.type != ProgramHeaderType.load) continue;

            // Validate segment.
            if (prog_hdr.mem_size < prog_hdr.file_size) {
                _error = Error.MemSizeLessThanFileSize;
                break :ok_blk;
            }
            if (prog_hdr.virt_addr + prog_hdr.mem_size < prog_hdr.virt_addr) {
                _error = Error.AddressOverflow;
                break :ok_blk;
            }
            if (prog_hdr.virt_addr % riscv.pg_size != 0) {
                _error = Error.AddressNotAligned;
                break :ok_blk;
            }

            // Allocate memory for the segment.
            size = vm.uvmMalloc(
                page_table.?,
                size,
                prog_hdr.virt_addr + prog_hdr.mem_size,
                flagsToPerm(prog_hdr.flags),
            ) catch |e| {
                _error = e;
                break :ok_blk;
            };

            // Load the segment's data from inode to memory.
            loadSeg(
                page_table.?,
                prog_hdr.virt_addr,
                inode_ptr.?,
                prog_hdr.offset,
                prog_hdr.file_size,
            ) catch |e| {
                _error = e;
                break :ok_blk;
            };
        }
        inode_ptr.?.unlockPut();
        log.endOp();
        inode_ptr = null;

        proc = Process.current() catch panic(
            @src(),
            "current proc is null",
            .{},
        ); // Gets the current process again (in case it was swapped out).
        const old_size = proc.size;

        // Allocate some pages at the next page boundary.
        // Make the first inaccessible as a stack guard.
        // Use the rest as the user stack.
        size = riscv.pgRoundUp(size);
        const stack_size = (param.user_stack + 1) * riscv.pg_size; // +1 is for guard page
        size = vm.uvmMalloc(
            page_table.?,
            size,
            size + stack_size,
            @intFromEnum(riscv.PteFlag.w),
        ) catch |e| {
            _error = e;
            break :ok_blk;
        };
        vm.uvmClear(page_table, size - stack_size); // clears the guard page
        const stack_pointer = size;
        const stack_base = stack_pointer - param.user_stack * riscv.pg_size;

        // Push argument strings, prepare rest of stack in ustack.
        var ustack = [_]u64{0} ** param.max_arg;
        for (argv, 0..) |arg, j| {
            const arg_len_with_null_terminated = mem.len(arg) + 1;
            stack_pointer -= arg_len_with_null_terminated;
            stack_pointer -= (stack_pointer % 16);
            if (stack_pointer < stack_base) {
                _error = Error.StackOverflow;
                break :ok_blk;
            }
            vm.copyOut(
                page_table.?,
                stack_pointer,
                arg,
                arg_len_with_null_terminated,
            ) catch |e| {
                _error = e;
                break :ok_blk;
            };
            ustack[j] = stack_pointer;
        }
        ustack[argv.len] = 0;

        // Push the array of argv[] pointers.
        const argv_array_size = (argv.len + 1) * @sizeOf(u64);
        stack_pointer -= argv_array_size;
        stack_pointer -= stack_pointer % 16;
        if (stack_pointer < stack_base) {
            _error = Error.StackOverflow;
            break :ok_blk;
        }
        vm.copyOut(
            page_table.?,
            stack_pointer,
            @as([*]const u8, ustack),
            argv_array_size,
        ) catch |e| {
            _error = e;
            break :ok_blk;
        };

        // arguments to user main(argc, argv)
        // argc is returned via the system call return
        // value, which goes in a0.
        proc.trap_frame.a1 = stack_pointer;

        // Save program name for debugging.
        var name_slice: []const u8 = undefined;
        if (mem.lastIndexOfScalar(u8, _path, '/')) |last| {
            name_slice = _path[last + 1 ..];
        } else {
            name_slice = _path;
        }
        misc.safeStrCopy(&proc.name, name_slice, proc.name.len);

        // Commit to the user image.
        const old_page_table = page_table.?;
        proc.page_table = page_table;
        proc.size = size;
        proc.trap_frame.epc = elf_hdr.entry;
        proc.trap_frame.sp = stack_pointer;
        Process.freePageTable(old_page_table, old_size);

        return @intCast(argv.len); // this ends up in a0, the first argument to main(argc, argv)
    }

    if (page_table) |pgtbl| {
        Process.freePageTable(pgtbl, size);
    }
    if (inode_ptr) |ip| {
        ip.unlockPut();
        log.endOp();
    }
    return _error;
}
