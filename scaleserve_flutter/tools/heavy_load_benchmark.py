#!/usr/bin/env python3
"""ScaleServe remote compute validation benchmark.

This script is intentionally CPU/RAM heavy so you can verify that workload
actually runs on the remote machine.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import queue
import socket
import sys
import tempfile
import time
from multiprocessing import Process, Queue, freeze_support


def _worker(worker_id: int, duration_s: int, out_queue: Queue) -> None:
    """Burn CPU with repeated PBKDF2 work for duration_s."""
    try:
        start = time.time()
        rounds = 0
        digest_tail = ""
        salt = f"scaleserve-worker-{worker_id}".encode("utf-8")

        while time.time() - start < duration_s:
            payload = f"{worker_id}-{rounds}-{time.time_ns()}".encode("utf-8")
            digest = hashlib.pbkdf2_hmac("sha256", payload, salt, 150_000)
            digest_tail = digest.hex()[-16:]
            rounds += 1

        out_queue.put((worker_id, rounds, digest_tail))
    except Exception as exc:  # pragma: no cover - defensive
        out_queue.put((worker_id, -1, f"error:{type(exc).__name__}:{exc}"))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a heavy workload to validate remote compute execution."
    )
    parser.add_argument(
        "--seconds",
        type=int,
        default=45,
        help="Duration of CPU burn in seconds (default: 45).",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=max(2, (os.cpu_count() or 2) // 2),
        help="Number of worker processes (default: half available cores, min 2).",
    )
    parser.add_argument(
        "--ram-mb",
        type=int,
        default=512,
        help="Approx memory to allocate in MB before CPU run (default: 512).",
    )
    parser.add_argument(
        "--stamp-file",
        default=os.path.join(
            tempfile.gettempdir(), "scaleserve_remote_benchmark_stamp.txt"
        ),
        help="Server-side stamp file written during run.",
    )
    return parser.parse_args()


def _allocate_memory(ram_mb: int) -> list[bytearray]:
    blocks: list[bytearray] = []
    if ram_mb <= 0:
        return blocks

    for _ in range(ram_mb):
        blocks.append(bytearray(1024 * 1024))
    return blocks


def main() -> int:
    freeze_support()
    args = _parse_args()
    started_at = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    hostname = socket.gethostname()
    uname = platform.platform()
    cpu_count = os.cpu_count() or 1
    pid = os.getpid()
    user = os.environ.get("USER") or os.environ.get("USERNAME") or "unknown"

    print("=== ScaleServe Heavy Load Benchmark ===", flush=True)
    print(f"Started at: {started_at}", flush=True)
    print(f"Host: {hostname}", flush=True)
    print(f"User: {user}", flush=True)
    print(f"PID: {pid}", flush=True)
    print(f"Platform: {uname}", flush=True)
    print(f"CPU cores reported: {cpu_count}", flush=True)
    print(f"Requested workers: {args.workers}", flush=True)
    print(f"Requested RAM MB: {args.ram_mb}", flush=True)
    print(f"Working dir: {os.getcwd()}", flush=True)
    print(f"Python: {sys.version.split()[0]}", flush=True)
    print(flush=True)

    try:
        memory_blocks = _allocate_memory(args.ram_mb)
        print(f"Allocated RAM blocks: {len(memory_blocks)} MB", flush=True)
    except MemoryError:
        print(
            "Memory allocation failed. Lower --ram-mb and retry.",
            file=sys.stderr,
            flush=True,
        )
        return 2

    stamp_text = (
        f"host={hostname}\n"
        f"user={user}\n"
        f"pid={pid}\n"
        f"started_at={started_at}\n"
        f"workers={args.workers}\n"
        f"seconds={args.seconds}\n"
    )
    try:
        with open(args.stamp_file, "w", encoding="utf-8") as handle:
            handle.write(stamp_text)
        print(f"Wrote stamp: {args.stamp_file}", flush=True)
    except OSError as exc:
        print(f"Warning: could not write stamp file ({exc})", file=sys.stderr, flush=True)

    q: Queue = Queue()
    procs: list[Process] = []
    run_start = time.time()
    for worker_id in range(args.workers):
        proc = Process(target=_worker, args=(worker_id, args.seconds, q))
        proc.start()
        procs.append(proc)

    # Prevent indefinite hangs if a child crashes and never reports.
    deadline = run_start + args.seconds + 120
    results_by_worker: dict[int, tuple[int, int, str]] = {}
    while len(results_by_worker) < len(procs):
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        try:
            worker_id, rounds, digest_tail = q.get(timeout=min(5.0, remaining))
        except queue.Empty:
            continue
        results_by_worker[worker_id] = (worker_id, rounds, digest_tail)

    for proc in procs:
        proc.join(timeout=5)
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=2)
            if proc.is_alive():
                proc.kill()
                proc.join(timeout=1)

    elapsed = time.time() - run_start
    results = sorted(results_by_worker.values(), key=lambda item: item[0])
    total_rounds = sum(rounds for _, rounds, _ in results)
    missing_workers = [i for i in range(args.workers) if i not in results_by_worker]

    print(flush=True)
    print("=== Worker Results ===", flush=True)
    for worker_id, rounds, digest_tail in results:
        status = "ok" if rounds >= 0 else "error"
        print(
            f"worker={worker_id} rounds={rounds} digest_tail={digest_tail} status={status}",
            flush=True,
        )
    if missing_workers:
        print(
            f"missing_workers={','.join(str(i) for i in missing_workers)}",
            file=sys.stderr,
            flush=True,
        )

    print(flush=True)
    print("=== Summary ===", flush=True)
    print(f"Elapsed seconds: {elapsed:.2f}", flush=True)
    print(f"Total rounds: {total_rounds}", flush=True)
    print(f"Rounds/sec: {total_rounds / max(elapsed, 0.001):.2f}", flush=True)

    with tempfile.NamedTemporaryFile(
        prefix="scaleserve-bench-", suffix=".txt", delete=False
    ) as temp_file:
        temp_file.write(
            (
                f"host={hostname}\n"
                f"elapsed={elapsed:.2f}\n"
                f"total_rounds={total_rounds}\n"
            ).encode("utf-8")
        )
        temp_path = temp_file.name

    print(f"Temp benchmark file: {temp_path}", flush=True)
    if missing_workers:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
