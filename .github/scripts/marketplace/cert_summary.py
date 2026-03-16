#!/usr/bin/env python3
"""Reads certification_scan_report.json and prints a Markdown summary to stdout.
Called by the GitHub Actions workflow: python cert_summary.py >> $GITHUB_STEP_SUMMARY
"""
import json
import sys
import os

report_path = os.path.join(os.environ.get("GITHUB_WORKSPACE", "."), "certification_scan_report.json")

if not os.path.exists(report_path):
    print("## Certification Scan\n\nNo report file found.")
    sys.exit(0)

data = json.load(open(report_path))
cve = [d for d in data if d.get("needs_cve_update")]
other_failed = [d for d in data if d.get("status") == "FAILED_OTHER"]
clean = [d for d in data if d.get("status") in ("CLEAN", "NO_SUBMISSIONS")]

print("## Certification Scan Summary\n")

print(f"### CVE Updates Required: {len(cve)} offer(s)")
if cve:
    for d in cve:
        print(f"\n**{d['product']}** `{d['product_id']}`")
        print(f"- State: `{d.get('failed_submission_state', 'N/A')}`")
        print(f"- [View Report]({d['partner_center_url']})")
        for issue in d["cve_issues"][:5]:
            print(f"  - `{issue['code']}`: {issue['message'][:200]}")
else:
    print("All offers pass CVE checks.\n")

if other_failed:
    print(f"\n### Other Failures: {len(other_failed)} offer(s)")
    for d in other_failed:
        print(f"- **{d['product']}**: {d.get('current_state','N/A')}")

print(f"\n### Clean: {len(clean)} offer(s)")
for d in clean:
    print(f"- {d['product']}: `{d.get('current_state','N/A')}`")
