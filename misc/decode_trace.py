#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

SYMBOLIZER_COMMAND = "llvm-symbolizer"
KERNEL_IMAGE_PATH = (
    Path(__file__).resolve().parent / "../zig-out/kernel/kernel"
).resolve()
ADDRESS_PATTERN = re.compile(r"0x[0-9a-fA-F]+")
IGNORED_SUFFIXES = {"start", "_entry"}


def read_log_block() -> str:
    print("Paste the log between two identical delimiter lines made of '=' characters.")
    print("End the input right after repeating the delimiter line.")
    collected_lines = []
    delimiter_line = None

    while True:
        try:
            line = input()
        except EOFError:
            break

        collected_lines.append(line)

        if delimiter_line is None and "=" * 5 in line:
            delimiter_line = line
            continue

        if (
            delimiter_line is not None
            and line == delimiter_line
            and len(collected_lines) > 1
        ):
            break

    return "\n".join(collected_lines)


def extract_unique_addresses(log_text: str) -> list[str]:
    unique_addresses = {}
    for match in ADDRESS_PATTERN.findall(log_text):
        lower_match = match.lower()
        if lower_match not in unique_addresses:
            numeric_value = int(match, 16)
            adjusted_value = numeric_value - 1 if numeric_value > 0 else 0
            unique_addresses[lower_match] = f"0x{adjusted_value:x}"
    return list(unique_addresses.values())


def symbolize_addresses(addresses: list[str]) -> str:
    if not KERNEL_IMAGE_PATH.exists():
        raise FileNotFoundError(f"Kernel image not found at: {KERNEL_IMAGE_PATH}")

    symbolizer_args = [
        SYMBOLIZER_COMMAND,
        f"--obj={KERNEL_IMAGE_PATH}",
        "--pretty-print",
        "--print-source-context-lines=10",
    ]
    address_payload = "\n".join(addresses) + "\n"

    try:
        completed = subprocess.run(
            symbolizer_args,
            input=address_payload.encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError as error:
        raise RuntimeError(
            f"{SYMBOLIZER_COMMAND} not found in PATH. Ensure LLVM tools are installed."
        ) from error

    if completed.returncode != 0:
        error_message = completed.stderr.decode(errors="replace").strip()
        raise RuntimeError(
            f"{SYMBOLIZER_COMMAND} failed with exit code {completed.returncode}: {error_message}"
        )

    return completed.stdout.decode(errors="replace")


def trim_bootstrap_frames(symbolizer_output: str) -> str:
    blocks = symbolizer_output.strip().split("\n\n")
    filtered = []
    for block in blocks:
        first_line = block.splitlines()[0]
        function_name = first_line.split(" at ", 1)[0].strip()
        if function_name in IGNORED_SUFFIXES:
            break
        filtered.append(block)
    return "\n\n".join(filtered) + "\n"


def main() -> None:
    log_text = read_log_block()
    if not log_text.strip():
        print("No log input received. Exiting.")
        return

    addresses = extract_unique_addresses(log_text)
    if not addresses:
        print("No hexadecimal addresses were found in the provided log.")
        return

    try:
        symbolized_output = symbolize_addresses(addresses)
        symbolized_output = trim_bootstrap_frames(symbolized_output)
    except Exception as runtime_error:
        print(f"Symbolization failed: {runtime_error}", file=sys.stderr)
        sys.exit(1)

    heading = "Decoded stack trace"
    underline = "-" * len(heading)
    print()
    print(underline)
    print(heading)
    print(underline)
    print(symbolized_output, end="")


if __name__ == "__main__":
    main()
