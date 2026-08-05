#!/usr/bin/env python3
import json
import sys
from pathlib import Path

GIB = 1024 ** 3
WARNING_BYTES = 30 * GIB
REJECT_BYTES = 25 * GIB
EMERGENCY_BYTES = 20 * GIB


def fail(message, status=77):
    print(f"RESOURCE_GATE_INVALID reason={message}", file=sys.stderr)
    raise SystemExit(status)


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid_json:{type(error).__name__}")


def normalized_url(value):
    return str(value or "").rstrip("/")


def main():
    if len(sys.argv) != 4:
        fail("usage")
    controller = load_json(sys.argv[1])
    computers = load_json(sys.argv[2])
    own_build_url = normalized_url(sys.argv[3])
    if not own_build_url:
        fail("missing_build_url")

    monitor = controller.get("monitorData", {}).get("hudson.node_monitors.DiskSpaceMonitor")
    available = monitor.get("size") if isinstance(monitor, dict) else None
    if not isinstance(available, int) or isinstance(available, bool) or available < 0:
        fail("missing_disk_telemetry")

    active = []
    for computer in computers.get("computer", []):
        executors = computer.get("executors", []) + computer.get("oneOffExecutors", [])
        for executor in executors:
            current = executor.get("currentExecutable")
            if isinstance(current, dict) and current.get("url"):
                active.append(normalized_url(current["url"]))
    active_others = sum(url != own_build_url for url in active)

    if available < EMERGENCY_BYTES:
        state, status, exit_code = "EMERGENCY", "BLOCKED", 78
    elif available < REJECT_BYTES:
        state, status, exit_code = "BLOCKED", "BLOCKED", 78
    elif available < WARNING_BYTES and active_others:
        state, status, exit_code = "CONCURRENCY_BLOCKED", "BLOCKED", 79
    elif available < WARNING_BYTES:
        state, status, exit_code = "WARNING", "OK", 0
    else:
        state, status, exit_code = "NORMAL", "OK", 0

    print(
        "RESOURCE_GATE_EVIDENCE "
        f"available_bytes={available} warning_bytes={WARNING_BYTES} "
        f"reject_bytes={REJECT_BYTES} emergency_bytes={EMERGENCY_BYTES} "
        f"active_others={active_others} state={state} status={status}"
    )
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
