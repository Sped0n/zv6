# zv6

A **_complete_** reimplementation of [xv6 (RISC-V)](https://github.com/mit-pdos/xv6-riscv) in Zig.

![demo](https://raw.githubusercontent.com/Sped0n/zv6/main/misc/demo.gif)

> The above video is at 10× speed.

## Features

- Kernel written in pure Zig.
- On par performance with the original C version, even slightly faster (~5s for usertests on my laptop).
- One build system (`build.zig`) for everything (kernel, userland, tools).
- Pass **_all_** userland test (`forktest`, `stressfs`, `grind` and `usertests`).

## Usage

All commands assume you are in the project root.

### Prerequisites

- Unix-like environment (Linux/macOS)
- Zig 0.15
- QEMU
- Perl
- LLDB (optional, for debugging)
- LLVM Binutils (optional, for debugging)

or just `nix develop` if you have Nix installed.

### Build

Build everything (mkfs, all user‐programs, fs.img, initcode, and the kernel):

```
zig build
```

To see all of the available build steps:

```
zig build --help
```

To rebuild the kernel (or any other single step) you can invoke it by name:

```
zig build mkfs       # compile the mkfs tool
zig build user       # compile all user programs
zig build image      # regenerate fs.img (depends on mkfs + user)
zig build initcode   # generate the initcode binary
zig build kernel     # compile the kernel
```

If you just want to recompile the kernel & skip recreating your disk image:

```
zig build kernel -Dkeep-fsimg
```

### Run

Start QEMU, boot the kernel, mount `fs.img` over virtio:

```
zig build qemu
```

You should see the xv6-ish boot output and land in the shell.

### Debug

Launch QEMU suspended with a GDB stub on TCP port 3333:

```
zig build qemu-gdb
```

In another terminal, start your LLDB and connect:

```
$ lldb zig-out/kernel/kernel --local-lldbinit
(lldb) gdb-remote localhost:3333
(lldb) c
```

### Trace

Run QEMU with instruction tracing enabled; output goes to `qemu_debug.log`:

```
zig build qemu-trace
```

You can then inspect `qemu_debug.log` for guest errors, instruction dumps, etc.

### Stack Trace Decode

Powered by `llvm-symbolizer`, run the script and paste in the stack trace you want to decode:

```
$ chmod +x ./misc/decode_trace.py
$ ./misc/decode_trace.py
Paste the log between two identical delimiter lines made of '=' characters.
End the input right after repeating the delimiter line.
[ERROR] diag    | ========================================
[ERROR] diag    | CPU 0 panicked: reached unreachable code
[ERROR] diag    | Stack trace:
[ERROR] diag    |   0x8000573e
[ERROR] diag    |   0x800055ec
[ERROR] diag    |   0x8000001e
[ERROR] diag    | ========================================

-------------------
Decoded stack trace
-------------------
main.main at /Users/spedon/eden/zig/zv6/kernel/main.zig:42:19
37  :         virtio_disk.init();
38  :         Process.userInit();
39  :
40  :         log.info("Hardware thread {d} started", .{cpu_id});
41  :
42 >:         if (true) unreachable;
43  :
44  :         @atomicStore(
45  :             bool,
46  :             &started,

.Lpcrel_hi425 at /Users/spedon/eden/zig/zv6/kernel/start.zig:54:14
49  :     // access to all of physical memory.
50  :     riscv.pmpaddr0.write(@as(u64, 0x3fffffffffffff));
51  :     riscv.pmpcfg0.write(@as(u64, 0xf));
52  :
53  :     // ask for clock interrupts.
54 >:     timerInit();
55  :
56  :     // keep each CPU's hartid in its tp register, for cpuid().
57  :     const cpu_id = riscv.mhartid.read();
58  :     riscv.tp.write(cpu_id);
```

## Credits

- https://github.com/mit-pdos/xv6-riscv
- https://github.com/skyzh/core-os-riscv
- https://xiayingp.gitbook.io/build_a_os
- https://github.com/tzx/nOSering
- https://github.com/saza-ku/xv6-zig
- https://github.com/candrewlee14/xv6-riscv-zig
- https://github.com/smallkirby/writing-hypervisor-in-zig
- https://github.com/rmehri01/xv6
