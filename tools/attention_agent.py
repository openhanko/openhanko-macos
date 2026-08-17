#!/usr/bin/env python3
"""Lights the device's LED when macOS starts a smart-card authentication.

The card itself cannot know: macOS does not power it on, or send it a single
byte, until a PIN has been submitted — and on this device the PIN is submitted
by its own HID typing, which the button press triggers. See the trace in
README.md. So a prompt-before-you-act signal has to come from the host.

This watches the unified log for Apple's PAM smart-card module and drives the
firmware's ATTENTION command over the CDC console:

    pam_sm_authenticate(): SmartCard -            -> ATTENTION ON
    SmartCard - Smartcard verification result     -> ATTENTION OFF

It never touches the PAM stack. Worst case it stops working and the LED simply
stays dark; it cannot interfere with authentication.

    ./tools/attention_agent.py --check     watch and print, without a device
    ./tools/attention_agent.py             run it for real
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import provision  # noqa: E402  (same directory, shares the console plumbing)

# Matched against each log line. These are Apple's *debug* strings, which is the
# fragile part of this design: they are not API and can change between releases.
# --check prints what is actually arriving so a mismatch is visible rather than
# silent. Widen or adjust here if a macOS update breaks it.
START_PATTERNS = ("pam_sm_authenticate(): SmartCard",)
DONE_PATTERNS = ("Smartcard verification result",)

LOG_PREDICATE = 'eventMessage CONTAINS "pam_sm_authenticate"'

# One authentication emits several matching lines; do not re-send for each.
RETRIGGER_SECONDS = 2.0


def log_stream():
    """Yields lines from `log stream`, restarting it if it dies."""
    while True:
        proc = subprocess.Popen(
            ["log", "stream", "--predicate", LOG_PREDICATE,
             "--level", "debug", "--style", "compact"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            for line in proc.stdout or ():
                yield line.rstrip()
        finally:
            proc.kill()
            proc.wait()
        # `log` exiting is not normal; back off so a persistent failure does not
        # spin the CPU.
        time.sleep(2.0)


class Device:
    """Finds the device's CDC console and sends it one-line commands.

    The port is opened per command rather than held, so provision.py can still
    talk to the device while this is running.
    """

    def __init__(self, explicit_port: str | None) -> None:
        self.explicit = explicit_port
        self.port: str | None = None

    def _verify(self, port: str) -> bool:
        try:
            with provision.Console(port) as console:
                return any(line == "PONG" for line in console.send("PING", timeout=3))
        except Exception:
            return False

    def _discover(self) -> str | None:
        if self.explicit:
            return self.explicit if self._verify(self.explicit) else None
        for candidate in provision.list_ports():
            if self._verify(candidate):
                return candidate
        return None

    def send(self, command: str) -> bool:
        for attempt in (1, 2):
            if self.port is None:
                self.port = self._discover()
                if self.port is None:
                    return False
            try:
                with provision.Console(self.port) as console:
                    console.send(command, timeout=3, echo=False)
                return True
            except Exception:
                # Stale port after a replug or reboot: rediscover once.
                self.port = None
                if attempt == 2:
                    return False
        return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", help="CDC device path; autodetected otherwise")
    parser.add_argument("--check", action="store_true",
                        help="print matching log lines without driving a device")
    args = parser.parse_args()

    device = None if args.check else Device(args.port)
    if device is not None:
        found = device._discover()
        print(f"device: {found or 'not found yet, will retry on first event'}", flush=True)
    print("watching for smart-card authentications; Ctrl-C to stop", flush=True)

    last_start = 0.0
    try:
        for line in log_stream():
            now = time.monotonic()

            if any(pattern in line for pattern in DONE_PATTERNS):
                verdict = "ok" if line.rstrip().endswith("0") else "failed"
                print(f"[{time.strftime('%H:%M:%S')}] authentication finished ({verdict})",
                      flush=True)
                if device is not None:
                    device.send("ATTENTION OFF")
                last_start = 0.0
                continue

            if any(pattern in line for pattern in START_PATTERNS):
                if now - last_start < RETRIGGER_SECONDS:
                    continue
                last_start = now
                print(f"[{time.strftime('%H:%M:%S')}] authentication started -> ATTENTION ON",
                      flush=True)
                if device is not None and not device.send("ATTENTION ON"):
                    print("   (device not reachable)", flush=True)

            elif args.check:
                print(f"   unmatched: {line[:140]}", flush=True)
    except KeyboardInterrupt:
        if device is not None:
            device.send("ATTENTION OFF")
        print("", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
