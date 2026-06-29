#!/usr/bin/env python3
"""Run multiple injected configs sequentially inside one Batch container."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
from pathlib import Path


def _decode_configs(dest: Path) -> list[Path]:
    payload = os.environ.get("RUN_MANY_CONFIGS_B64")
    if not payload:
        raise SystemExit("RUN_MANY_CONFIGS_B64 is required")

    dest.mkdir(parents=True, exist_ok=True)
    items = json.loads(base64.b64decode(payload).decode("utf-8"))
    if not isinstance(items, list) or not items:
        raise SystemExit("RUN_MANY_CONFIGS_B64 must contain a non-empty config list")

    paths: list[Path] = []
    for idx, item in enumerate(items, start=1):
        name = str(item.get("name") or f"config_{idx:03d}.yml")
        if "/" in name or name in {"", ".", ".."}:
            raise SystemExit(f"invalid config name: {name!r}")
        config_b64 = item.get("config_b64")
        if not isinstance(config_b64, str):
            raise SystemExit(f"missing config_b64 for item {idx}")
        path = dest / f"{idx:03d}_{name}"
        path.write_bytes(base64.b64decode(config_b64))
        paths.append(path)
    return paths


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entry", default="rtrrl.py")
    parser.add_argument("--logging", default="aim")
    parser.add_argument("--log_repo", default=None)
    parser.add_argument("--workdir", default="/tmp/run-many-configs")
    parser.add_argument("--fail-fast", action="store_true")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    extra = list(args.extra)
    if extra and extra[0] == "--":
        extra = extra[1:]

    configs = _decode_configs(Path(args.workdir))
    failures: list[tuple[Path, int]] = []
    for idx, config in enumerate(configs, start=1):
        cmd = [
            sys.executable,
            args.entry,
            "--config_path",
            str(config),
            "--logging",
            args.logging,
        ]
        if args.log_repo and "aim" in args.logging:
            cmd += ["--log_repo", args.log_repo]
        cmd += extra

        print(f"[run_many] ({idx}/{len(configs)}) running {config.name}: {' '.join(cmd)}", flush=True)
        result = subprocess.run(cmd, check=False)
        if result.returncode != 0:
            failures.append((config, result.returncode))
            print(
                f"[run_many] {config.name} failed with exit code {result.returncode}",
                flush=True,
            )
            if args.fail_fast:
                break

    if failures:
        print("[run_many] failures:", flush=True)
        for config, code in failures:
            print(f"  {config.name}: exit {code}", flush=True)
        return 1

    print(f"[run_many] completed {len(configs)} configs", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
