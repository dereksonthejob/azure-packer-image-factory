#!/usr/bin/env python3
"""
full_cert_history_scan.py

Discovers ALL products from Partner Center via Graph Ingestion API,
reads every submission in their history, fetches any available
certification report / validation errors, and flags those with
CVE or security-related failure messages.

Output: structured console report + certification_full_scan.json artifact.
Authentication: single Graph API token (https://graph.microsoft.com/.default)
"""

import requests
import msal
import json
import os
import sys
from datetime import datetime

CVE_KEYWORDS = [
    "cve", "vulnerability", "vulnerabilities", "security update",
    "outdated", "patch", "kernel", "out-of-date", "critical update",
    "security advisory", "unpatched", "exploit", "exposure",
    "critical", "high severity", "malware", "antivirus", "defender",
    "end of life", "end-of-life", "eol", "deprecated"
]

# All Graph Ingestion API calls use the same base
GRAPH_BASE = "https://graph.microsoft.com/rp/product-ingestion"
GRAPH_API_VER = "?api-version=2022-03-01-preview2"


def get_token(client_id, tenant_id, client_secret):
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.ConfidentialClientApplication(
        client_id, authority=authority, client_credential=client_secret
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        print(f"[AUTH ERROR] {result.get('error_description')}")
        sys.exit(1)
    return result["access_token"]


def safe_get(url, headers, label=""):
    try:
        r = requests.get(url, headers=headers, timeout=20)
        if r.status_code == 200:
            return r.json()
        print(f"  [HTTP {r.status_code}] {label}")
        return {}
    except Exception as e:
        print(f"  [NET ERROR] {label}: {e}")
        return {}


def list_all_products(headers):
    """
    Enumerate every product in the Partner Center account.
    Uses Graph Ingestion API: GET /product (paginated).
    Only returns VM and Container offers by default (can be extended).
    """
    url = f"{GRAPH_BASE}/product{GRAPH_API_VER}"
    products = []
    while url:
        data = safe_get(url, headers, "list products")
        products.extend(data.get("value", []))
        url = data.get("@nextLink")
    return products


def list_submissions(product_id, headers):
    """Return all historical submissions for a product, newest first."""
    url = f"{GRAPH_BASE}/submissions{GRAPH_API_VER}&product=product/{product_id}"
    data = safe_get(url, headers, f"submissions for {product_id}")
    subs = data.get("value", [])
    return sorted(subs, key=lambda s: s.get("createdDateTime", ""), reverse=True)


def get_validations(submission_id, headers):
    """Fetch validation errors for a specific submission."""
    url = f"{GRAPH_BASE}/submissions/{submission_id}/validations{GRAPH_API_VER}"
    data = safe_get(url, headers, f"validations for {submission_id}")
    if "value" in data:
        return data["value"]
    if "validations" in data:
        return data["validations"]
    if isinstance(data, list):
        return data
    return []


def is_cve_related(text):
    tl = text.lower()
    return any(kw in tl for kw in CVE_KEYWORDS)


def extract_text(v):
    """Pull any human-readable text out of a validation object."""
    parts = []
    for key in ("message", "description", "title", "code", "errorCode"):
        val = v.get(key)
        if val and isinstance(val, str):
            parts.append(val)
        elif val and isinstance(val, dict):
            parts.append(json.dumps(val)[:200])
    return " | ".join(parts)


def scan_product(product_id, product_name, headers):
    result = {
        "product": product_name,
        "product_id": product_id,
        "submissions_scanned": 0,
        "cve_submissions": [],
        "other_failed_submissions": [],
        "needs_cve_update": False,
        "partner_center_url": (
            f"https://partner.microsoft.com/en-us/dashboard/commercial-marketplace"
            f"/offers/{product_id}/overview"
        ),
    }

    submissions = list_submissions(product_id, headers)
    result["submissions_scanned"] = len(submissions)

    for sub in submissions:
        sub_id = sub.get("id", "")
        state = sub.get("state", "")
        created = sub.get("createdDateTime", "N/A")
        report_url = (
            f"https://partner.microsoft.com/en-us/dashboard/commercial-marketplace"
            f"/offers/{product_id}/certification/reports/{sub_id}"
        )

        validations = get_validations(sub_id, headers)

        cve_issues = []
        other_issues = []
        for v in validations:
            text = extract_text(v)
            severity = str(v.get("severity", v.get("level", "unknown")))
            code = str(v.get("code", v.get("errorCode", "N/A")))
            issue = {"code": code, "severity": severity, "message": text[:300]}
            if is_cve_related(text):
                cve_issues.append(issue)
            elif severity.lower() in ("error", "critical", "blocker"):
                other_issues.append(issue)

        if cve_issues:
            result["cve_submissions"].append({
                "submission_id": sub_id,
                "state": state,
                "created": created,
                "report_url": report_url,
                "cve_issues": cve_issues,
            })
            result["needs_cve_update"] = True
        elif other_issues and "fail" in state.lower():
            result["other_failed_submissions"].append({
                "submission_id": sub_id,
                "state": state,
                "created": created,
                "report_url": report_url,
                "issues": other_issues,
            })

    return result


def print_report(findings):
    print("\n" + "=" * 72)
    print("  PARTNER CENTER — FULL HISTORY CVE CERTIFICATION SCAN")
    print(f"  Run at: {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"  Offers scanned: {len(findings)}")
    print("=" * 72)

    cve_offers = [f for f in findings if f["needs_cve_update"]]
    failed_other = [
        f for f in findings
        if f["other_failed_submissions"] and not f["needs_cve_update"]
    ]
    clean = [
        f for f in findings
        if not f["needs_cve_update"] and not f["other_failed_submissions"]
    ]

    print(f"\n🔴  NEEDS CVE UPDATE  ({len(cve_offers)} offer(s))")
    print("-" * 72)
    if cve_offers:
        for f in cve_offers:
            print(f"\n  📦  {f['product']}")
            print(f"      ID      : {f['product_id']}")
            for s in f["cve_submissions"]:
                print(f"      State   : {s['state']}  |  Created: {s['created']}")
                print(f"      Report  : {s['report_url']}")
                for issue in s["cve_issues"][:5]:
                    print(f"      [{issue['severity'].upper()}] {issue['code']}: "
                          f"{issue['message'][:200]}")
    else:
        print("  ✅  None — no CVE failures found across all offers.")

    print(f"\n🟡  FAILED (Other Reasons)  ({len(failed_other)} offer(s))")
    print("-" * 72)
    if failed_other:
        for f in failed_other:
            print(f"\n  📦  {f['product']}  [{f['product_id']}]")
            for s in f["other_failed_submissions"][:2]:
                print(f"      State: {s['state']}  |  Report: {s['report_url']}")
                for issue in s["issues"][:2]:
                    print(f"      [{issue['severity'].upper()}] {issue['code']}: "
                          f"{issue['message'][:150]}")
    else:
        print("  ✅  None.")

    print(f"\n🟢  CLEAN  ({len(clean)} offer(s))")
    print("-" * 72)
    for f in clean:
        subs = f["submissions_scanned"]
        print(f"  ✅  {f['product']}  ({subs} submission(s) scanned)")

    print("\n" + "=" * 72)

    if cve_offers:
        names = ", ".join(o["product"] for o in cve_offers)
        print(f"\n::error title=CVE Updates Required::Offers needing CVE updates: {names}")
        sys.exit(1)
    else:
        print("\n::notice title=CVE Scan Clean::All offers passed CVE certification check.")


def main():
    client_id = os.environ.get("AZURE_CLIENT_ID")
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")

    if not all([client_id, tenant_id, client_secret]):
        print("[ERROR] Missing AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET")
        sys.exit(1)

    print("Authenticating to Microsoft Graph API...")
    token = get_token(client_id, tenant_id, client_secret)
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    print("✅ Authenticated.\n")

    print("Discovering all Partner Center offers...")
    products = list_all_products(headers)
    if not products:
        print("[WARN] No products returned. Check SP has 'Developer' role in "
              "Commercial Marketplace program in Partner Center.")
        sys.exit(0)

    # Filter to VM and Container offers only (skip consulting services, SaaS etc)
    vm_types = {"azureVirtualMachine", "azureContainer"}
    vm_products = [p for p in products if p.get("type") in vm_types]
    print(f"  Found {len(products)} total offer(s), {len(vm_products)} VM/Container offer(s):\n")
    for p in vm_products:
        pid = p.get("id", "").replace("product/", "")
        name = p.get("alias", p.get("name", pid))
        ext = p.get("identity", {}).get("externalId", "N/A")
        print(f"    • {name}  (extId={ext})  [{pid}]")

    print(f"\nScanning submission history for {len(vm_products)} VM/Container offer(s)...\n")

    findings = []
    for p in vm_products:
        pid = p.get("id", "").replace("product/", "")
        name = p.get("alias", p.get("name", pid))
        print(f"  → {name}  [{pid}]")
        result = scan_product(pid, name, headers)
        findings.append(result)
        cve_flag = "⚠️ CVE!" if result["needs_cve_update"] else "✅ clean"
        print(f"       {result['submissions_scanned']} submission(s) | {cve_flag}")

    print_report(findings)

    out_path = os.path.join(
        os.environ.get("GITHUB_WORKSPACE", "/tmp"),
        "certification_full_scan.json"
    )
    with open(out_path, "w") as fh:
        json.dump(findings, fh, indent=2)
    print(f"\n📄 Full JSON report: {out_path}")


if __name__ == "__main__":
    main()
