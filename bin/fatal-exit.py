#!/usr/bin/env python3
"""Terminate supervisord when any managed process gives up.

supervisord's default is to keep running with a process stuck in FATAL, which on
Railway means a container that reports healthy while gunicorn or the scheduler is
gone. Killing supervisord turns that into a restart the platform can see.
"""

import os
import signal
import sys


def main() -> None:
    while True:
        sys.stdout.write("READY\n")
        sys.stdout.flush()

        line = sys.stdin.readline()
        if not line:
            return
        headers = dict(pair.split(":", 1) for pair in line.split())
        payload = sys.stdin.read(int(headers.get("len", 0)))

        sys.stderr.write(f"[railway] process entered FATAL, stopping container: {payload}\n")
        sys.stderr.flush()

        sys.stdout.write("RESULT 2\nOK")
        sys.stdout.flush()

        os.kill(os.getppid(), signal.SIGTERM)
        return


if __name__ == "__main__":
    main()
