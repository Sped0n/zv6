#!/usr/bin/env python3
import argparse
import os
import pty
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


PASS_MARKER = "ALL TESTS PASSED"
FAIL_MARKER = "SOME TESTS FAILED"
SHELL_PROMPT = "$"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run zv6 usertests in QEMU through a controlled pseudo-terminal.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=900.0,
        help="maximum seconds to wait for usertests to pass (default: 900)",
    )
    parser.add_argument(
        "--keep-fsimg",
        action="store_true",
        help="pass -Dkeep-fsimg to zig build qemu",
    )
    parser.add_argument(
        "--usertests-arg",
        default="",
        help="optional single argument passed to usertests, such as -q or a test name",
    )
    return parser.parse_args()


def stop_process_group(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return

    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def main() -> None:
    args = parse_args()
    command = ["zig", "build", "qemu"]
    if args.keep_fsimg:
        command.append("-Dkeep-fsimg")

    usertests_command = "usertests"
    if args.usertests_arg:
        usertests_command += f" {args.usertests_arg}"
    usertests_command += "\n"

    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        command,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        cwd=repo_root(),
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave_fd)

    output = bytearray()
    sent_usertests = False
    status = "timeout"
    deadline = time.monotonic() + args.timeout

    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master_fd], [], [], 0.2)
            if master_fd in readable:
                try:
                    data = os.read(master_fd, 8192)
                except OSError:
                    break
                if not data:
                    break

                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                output.extend(data)
                if len(output) > 2_000_000:
                    del output[:-1_000_000]

                text = output.decode(errors="replace")
                if not sent_usertests and SHELL_PROMPT in text:
                    os.write(master_fd, usertests_command.encode())
                    sent_usertests = True

                if PASS_MARKER in text:
                    status = "passed"
                    break
                if FAIL_MARKER in text:
                    status = "failed"
                    break

            if proc.poll() is not None:
                status = "exited"
                break
    finally:
        stop_process_group(proc)
        os.close(master_fd)

    print(f"\nrun_usertests.py: status={status}", file=sys.stderr)
    if status == "passed":
        return
    if status == "timeout":
        sys.exit(124)
    sys.exit(1)


if __name__ == "__main__":
    main()
