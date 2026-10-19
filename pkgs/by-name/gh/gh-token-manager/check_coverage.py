#!/usr/bin/env python3
"""Fail when an llvm-cov JSON report has less than 95% line coverage."""

import json
import sys


MINIMUM_PERCENT = 95.0


def main() -> int:
    with open(sys.argv[1], encoding="utf-8") as report_file:
        report = json.load(report_file)

    totals = report["data"][0]["totals"]
    failed = False
    for metric in ("lines", "branches"):
        covered = int(totals[metric]["covered"])
        count = int(totals[metric]["count"])
        percent = 100.0 * covered / count if count else 100.0
        print(f"{metric.title()} coverage: {percent:.2f}% ({covered}/{count}); required: {MINIMUM_PERCENT:.0f}%")
        if metric == "branches" and count == 0:
            print("The coverage report contains no branch data.", file=sys.stderr)
            failed = True
        failed |= percent < MINIMUM_PERCENT
    if failed:
        for source_file in report["data"][0]["files"]:
            uncovered = sorted(
                {
                    int(segment[0])
                    for segment in source_file.get("segments", [])
                    if len(segment) > 3 and segment[3] and int(segment[2]) == 0
                }
            )
            print(f"Uncovered lines in {source_file['filename']}: {uncovered}")
            print(f"Branch records: {json.dumps(source_file.get('branches', []))}")
        print("Coverage is below the required threshold.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
