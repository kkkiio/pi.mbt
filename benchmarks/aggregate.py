#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Aggregate per-task harbor results from downloaded GitHub Actions artifacts.

Usage:
    gh run download <run-id> -D /tmp/tb-results -p 'tb-result-*'
    uv run benchmarks/aggregate.py /tmp/tb-results

Each artifact (tb-result-<task>) contains harbor's jobs-dir tree with one
trial. A trial's verdict lives in <trial_dir>/result.json (see
harbor.models.trial.result.TrialResult):

- verifier_result.rewards["reward"] == 1  -> PASS
- verifier_result present, reward != 1    -> FAIL
- exception_info set / no verifier result -> ERROR
- artifact present but no result.json     -> MISSING (trial crashed hard)
"""

import json
import sys
from pathlib import Path


def classify(result: dict) -> tuple[str, str]:
    exception = result.get("exception_info")
    verifier = result.get("verifier_result")
    rewards = (verifier or {}).get("rewards") or {}
    reward = rewards.get("reward")
    timing = result.get("agent_execution") or {}
    duration = ""
    if timing.get("started_at") and timing.get("finished_at"):
        from datetime import datetime

        start = datetime.fromisoformat(timing["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(timing["finished_at"].replace("Z", "+00:00"))
        duration = f"{(end - start).total_seconds() / 60:.0f}min"
    if reward == 1:
        return "PASS", duration
    if reward is not None:
        return "FAIL", duration
    if exception:
        return f"ERROR({exception.get('exception_type', '?')})", duration
    return "ERROR(no-verdict)", duration


def main() -> int:
    root = Path(sys.argv[1])
    rows: list[tuple[str, str, str]] = []
    for artifact_dir in sorted(root.iterdir()):
        if not artifact_dir.is_dir() or not artifact_dir.name.startswith(
            "tb-result-"
        ):
            continue
        task = artifact_dir.name.removeprefix("tb-result-")
        results = list(artifact_dir.rglob("result.json"))
        trial_results = []
        for result_path in results:
            result = json.loads(result_path.read_text())
            # Job-level result.json (JobResult) has stats, not task_name.
            if "task_name" in result:
                trial_results.append(result)
        if not trial_results:
            rows.append((task, "MISSING", ""))
            continue
        for result in trial_results:
            verdict, duration = classify(result)
            rows.append((result.get("task_name", task), verdict, duration))

    width = max((len(task) for task, _, _ in rows), default=0)
    n_pass = 0
    for task, verdict, duration in sorted(rows):
        print(f"{task:<{width}}  {verdict:<24} {duration}")
        if verdict == "PASS":
            n_pass += 1
    total = len(rows)
    pct = (100.0 * n_pass / total) if total else 0.0
    print(f"\n{n_pass}/{total}  ({pct:.1f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
