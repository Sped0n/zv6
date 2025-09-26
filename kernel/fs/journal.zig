const SpinLock = @import("../lock/SpinLock.zig");
const param = @import("../param.zig");
const assert = @import("../printf.zig").assert;
const panic = @import("../printf.zig").panic;
const Process = @import("../process/Process.zig");
const utils = @import("../utils.zig");
const fs = @import("fs.zig");

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

/// Contents of the header block, used for both the on-disk header block
/// and to keep track in memory of logged block# before commit.
const Header = extern struct {
    n: u32, // number of blocks
    block: [param.log_size]u32, // disk block numbers
};

var journal = struct {
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

pub fn init(dev: u32, super_block: *fs.SuperBlock) void {
    assert(@sizeOf(Header) < fs.block_size, @src());

    journal.lock.init("journal");
    journal.start = super_block.log_start;
    journal.size = super_block.n_log;
    journal.dev = dev;
    tryRecover();
}

/// Copy committed blocks from log to their home location
fn installTransaction(try_recover: bool) void {
    var tail: u32 = 0;
    while (tail < journal.header.n) : (tail += 1) {
        const journal_buffer = fs.Buffer.readFrom(
            journal.dev,
            journal.start + tail + 1,
        );
        const disk_buffer = fs.Buffer.readFrom(
            journal.dev,
            journal.header.block[tail],
        );
        defer disk_buffer.release();
        defer journal_buffer.release();

        utils.memMove(&disk_buffer.data, &journal_buffer.data, fs.block_size);
        disk_buffer.writeBack();
        if (!try_recover) disk_buffer.unPin();
    }
}

/// Read the journal header from disk into the in-memory log header
fn syncJournalFromDisk() void {
    const buffer = fs.Buffer.readFrom(journal.dev, journal.start);
    defer buffer.release();

    const journal_header = @as(
        [*]u8,
        @ptrCast(&journal.header),
    )[0..@sizeOf(@TypeOf(journal.header))];
    utils.memMove(journal_header, &buffer.data, journal_header.len);
}

/// Write in-memory log header to disk.
/// This is the true point at which the
/// current transaction commits.
fn syncJournalToDisk() void {
    const buffer = fs.Buffer.readFrom(journal.dev, journal.start);
    defer buffer.release();

    const journal_header = @as(
        [*]u8,
        @ptrCast(&journal.header),
    )[0..@sizeOf(@TypeOf(journal.header))];
    utils.memMove(&buffer.data, journal_header, journal_header.len);

    buffer.writeBack();
}

fn tryRecover() void {
    syncJournalFromDisk();
    defer syncJournalToDisk(); // clear the log

    installTransaction(true); // if committed, copy from log to disk
    journal.header.n = 0;
}

pub const batch = struct {
    /// called at the start of each FS syscall
    pub fn begin() void {
        journal.lock.acquire();
        while (true) {
            if (journal.committing) {
                Process.sleep(@intFromPtr(&journal), &journal.lock);
            } else if (journal.header.n + (journal.outstanding + 1) * param.max_opblocks > param.log_size) {
                // this op might exhaust log space; wait for commit.
                Process.sleep(@intFromPtr(&journal), &journal.lock);
            } else {
                journal.outstanding += 1;
                journal.lock.release();
                break;
            }
        }
    }

    /// called at the end of each FS system call.
    /// commits if this was the last outstanding operation.
    pub fn end() void {
        var do_commit = false;

        {
            journal.lock.acquire();
            defer journal.lock.release();

            journal.outstanding -= 1;
            assert(!journal.committing, @src());

            if (journal.outstanding == 0) {
                do_commit = true;
                journal.committing = true;
            } else {
                // begin_op() may be waiting for log space,
                // and decrementing log.outstanding has decreased
                // the amount of reserved space.
                Process.wakeUp(@intFromPtr(&journal));
            }
        }

        if (do_commit) {
            // call commit w/o holding locks, since not allowed
            // to sleep with locks.
            commit();
            journal.lock.acquire();
            defer journal.lock.release();
            journal.committing = false;
            Process.wakeUp(@intFromPtr(&journal));
        }
    }
};

/// Copy modified blocks from cache to log.
fn syncChangesToJournal() void {
    var tail: u32 = 0;
    while (tail < journal.header.n) : (tail += 1) {
        const to = fs.Buffer.readFrom(
            journal.dev,
            journal.start + tail + 1,
        );
        defer to.release();
        const from = fs.Buffer.readFrom(
            journal.dev,
            journal.header.block[tail],
        );
        defer from.release();

        utils.memMove(&to.data, &from.data, fs.block_size);
        to.writeBack(); // write the log
    }
}

fn commit() void {
    if (journal.header.n == 0) return;

    syncChangesToJournal(); // write modified blocks from cache to log
    syncJournalToDisk(); // write header to disk -- the real commit
    installTransaction(false); // now install writes to home locations
    journal.header.n = 0;
    syncJournalToDisk(); // erase the transcation from the log
}

/// Caller has modified b->data and is done with the buffer.
/// Record the block number and pin in the cache by increasing refcnt.
/// commit()/writeLog() will do the disk write.
///
/// log.write() replaces Buf.writeBack(); a typical use is:
///   bp = bread(...)
///   modify bp->data[]
///   log_write(bp)
///   brelse(bp)
pub fn write(buf: *fs.Buffer) void {
    journal.lock.acquire();
    defer journal.lock.release();

    if (journal.header.n >= @min(param.log_size, journal.size - 1))
        panic(@src(), "too big a transcation({d})", .{journal.header.n});
    if (journal.outstanding == 0)
        panic(@src(), "outside of transaction", .{});

    var i: u32 = 0;
    while (i < journal.header.n) : (i += 1) {
        if (journal.header.block[i] == buf.blockno) break; // log absorption
    }
    journal.header.block[i] = buf.blockno;
    if (i == journal.header.n) { // Add new block to log?
        buf.pin();
        journal.header.n += 1;
    }
}
