const SpinLock = @import("../lock/SpinLock.zig");
const memMove = @import("../misc.zig").memMove;
const misc = @import("../misc.zig");
const param = @import("../param.zig");
const assert = @import("../printf.zig").assert;
const panic = @import("../printf.zig").panic;
const Process = @import("../process/Process.zig");
const Buf = @import("Buf.zig");
const fs = @import("fs.zig");
const SuperBlock = @import("SuperBlock.zig").SuperBlock;

// Simple logging that allows concurrent FS system calls.
//
// A log transaction contains the updates of multiple FS system
// calls. The logging system only commits when there are
// no FS system calls active. Thus there is never
// any reasoning required about whether a commit might
// write an uncommitted system call's updates to disk.
//
// A system call should call begin_op()/end_op() to mark
// its start and end. Usually begin_op() just increments
// the count of in-progress FS system calls and returns.
// But if it thinks the log is close to running out, it
// sleeps until the last outstanding end_op() commits.
//
// The log is a physical re-do log containing disk blocks.
// The on-disk log format:
//   header block, containing block #s for block A, B, C, ...
//   block A
//   block B
//   block C
//   ...
// Log appends are synchronous.

///Contents of the header block, used for both the on-disk header block
///and to keep track in memory of logged block# before commit.
const Header = extern struct {
    n: u32, // number of blocks
    block: [param.log_size]u32, // disk block numbers
};

var log = struct {
    lock: SpinLock,
    start: u32,
    size: u32,
    outstanding: u32, // how many FS syscalls are executing.
    committing: bool, // in commit(), please wait
    dev: u32,
    header: Header,
}{
    .lock = undefined,
    .start = undefined,
    .size = undefined,
    .outstanding = 0,
    .committing = false,
    .dev = undefined,
    .header = Header{
        .n = 0,
        .block = [_]u32{0} ** param.log_size,
    },
};

pub fn init(dev: u32, super_block: *SuperBlock) void {
    assert(@sizeOf(Header) < fs.block_size, @src());

    log.lock.init("log");
    log.start = super_block.log_start;
    log.size = super_block.n_log;
    log.dev = dev;
    recoverFromLog();
}

///Copy committed blocks from log to their home location
fn installTrans(recovering: bool) void {
    var tail: u32 = 0;
    while (tail < log.header.n) : (tail += 1) {
        const log_buf = Buf.readFrom(log.dev, log.start + tail + 1);
        const disk_buf = Buf.readFrom(log.dev, log.header.block[tail]);
        defer {
            log_buf.release();
            disk_buf.release();
        }

        memMove(&disk_buf.data, &log_buf.data, fs.block_size);
        disk_buf.writeBack();
        if (!recovering) disk_buf.unPin();
    }
}

///Read the log header from disk into the in-memory log header
fn readHead() void {
    const buf = Buf.readFrom(log.dev, log.start);
    defer buf.release();

    const log_header = @as(
        [*]u8,
        @ptrCast(&log.header),
    )[0..@sizeOf(@TypeOf(log.header))];
    misc.memMove(log_header, &buf.data, log_header.len);
}

///Write in-memory log header to disk.
///This is the true point at which the
///current transaction commits.
fn writeHead() void {
    const buf = Buf.readFrom(log.dev, log.start);
    defer buf.release();

    const log_header = @as(
        [*]u8,
        @ptrCast(&log.header),
    )[0..@sizeOf(@TypeOf(log.header))];
    misc.memMove(&buf.data, log_header, log_header.len);

    buf.writeBack();
}

fn recoverFromLog() void {
    readHead();
    installTrans(true); // if committed, copy from log to disk
    log.header.n = 0;
    writeHead(); // clear the log
}

///called at the start of each FS syscall
pub fn beginOp() void {
    log.lock.acquire();
    while (true) {
        if (log.committing) {
            Process.sleep(@intFromPtr(&log), &log.lock);
        } else if (log.header.n + (log.outstanding + 1) * param.max_opblocks > param.log_size) {
            // this op might exhaust log space; wait for commit.
            Process.sleep(@intFromPtr(&log), &log.lock);
        } else {
            log.outstanding += 1;
            log.lock.release();
            break;
        }
    }
}

///called at the end of each FS system call.
///commits if this was the last outstanding operation.
pub fn endOp() void {
    var do_commit = false;

    {
        log.lock.acquire();
        defer log.lock.release();

        log.outstanding -= 1;
        assert(!log.committing, @src());

        if (log.outstanding == 0) {
            do_commit = true;
            log.committing = true;
        } else {
            // begin_op() may be waiting for log space,
            // and decrementing log.outstanding has decreased
            // the amount of reserved space.
            Process.wakeUp(@intFromPtr(&log));
        }
    }

    if (do_commit) {
        // call commit w/o holding locks, since not allowed
        // to sleep with locks.
        commit();
        log.lock.acquire();
        defer log.lock.release();
        log.committing = false;
        Process.wakeUp(@intFromPtr(&log));
    }
}

///Copy modified blocks from cache to log.
fn writeLog() void {
    var tail: u32 = 0;
    while (tail < log.header.n) : (tail += 1) {
        const to = Buf.readFrom(log.dev, log.start + tail + 1);
        defer to.release();
        const from = Buf.readFrom(
            log.dev,
            log.header.block[tail],
        );
        defer from.release();

        memMove(&to.data, &from.data, fs.block_size);
        to.writeBack(); // write the log
    }
}

fn commit() void {
    if (log.header.n == 0) return;

    writeLog(); // write modified blocks from cache to log
    writeHead(); // write header to disk -- the real commit
    installTrans(false); // now install writes to home locations
    log.header.n = 0;
    writeHead(); // erase the transcation from the log
}

///Caller has modified b->data and is done with the buffer.
///Record the block number and pin in the cache by increasing refcnt.
///commit()/writeLog() will do the disk write.
///
///log.write() replaces Buf.writeBack(); a typical use is:
///  bp = bread(...)
///  modify bp->data[]
///  log_write(bp)
///  brelse(bp)
pub fn write(buf: *Buf) void {
    log.lock.acquire();
    defer log.lock.release();

    if (log.header.n >= @min(param.log_size, log.size - 1))
        panic(@src(), "too big a transcation({d})", .{log.header.n});
    if (log.outstanding == 0)
        panic(@src(), "outside of transaction", .{});

    var i: u32 = 0;
    while (i < log.header.n) : (i += 1) {
        if (log.header.block[i] == buf.blockno) break; // log absorption
    }
    log.header.block[i] = buf.blockno;
    if (i == log.header.n) { // Add new block to log?
        buf.pin();
        log.header.n += 1;
    }
}
