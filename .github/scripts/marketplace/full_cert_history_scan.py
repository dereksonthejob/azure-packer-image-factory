#!/usr/bin/env python3
"""
full_cert_history_scan.py

Discovers ALL products from Partner Center via Ingestion API,
reads every submission in their history, fetches any available
certification report / validation errors, and flags those with
CVE or security-related failure messages.

Output: structured console report + certification_full_scan.json artifact.
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

# Partner Center REST API — used for listing all products
PC_API = "https://api.partner.microsoft.com"
PC_SCOPE = "https://api.partner.microsoft.com/.default"

# Graph Ingestion API — used for submissions and validations
GRAPH_BASE = "https://graph.microsoft.com/rp/product-ingestion"
GRAPH_API_VER = "?api-version=2022-03-01-preview2"


def get_token(client_id, tenant_id, client_secret, scope):
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.ConfidentialClientApplication(
        client_id, authority=authority, client_credential=client_secret
    )
    result = app.acquire_token_for_client(scopes=[scope])
    if "access_token" not in result:
        print(f"[AUTH ERROR] {result.get('error_description')}")
        sys.exit(1)
    return result["access_token"]


def safe_get(url, headers, label=""):
    try:
        r = requests.get(url, headers=headers, timeout=20)
        if r.status_code == 200:
            return r.json()
        return {}
    except Exception as e:
        print(f"  [NET ERROR] {label}: {e}")
        return {}


def list_all_products(pc_headers):
    """
    Enumerate every product using the Partner Center REST API.
    Endpoint: GET https://api.partner.microsoft.com/v1.0/ingestion/products
    This requires scope https://api.partner.microsoft.com/.default
    """
    url = f"{PC_API}/v1.0/ingestion/products?api-version=2022-07-01"
    products = []
    while url:
        data = safe_get(url, pc_headers, "list products")
        for item in data.get("value", []):
            products.append(item)
        url = data.get("@nextLink")
    return products


def list_submissions(product_id, graph_headers):
    """Return all historical submissions for a product, newest first."""
    url = f"{GRAPH_BASE}/submissions{GRAPH_API_VER}&product=product/{product_id}"
    data = safe_get(url, graph_headers, f"submissions {product_id}")
    subs = data.get("value", [])
    return sorted(subs, key=lambda s: s.get("createdDateTime", ""), reverse=True)


def get_validations(submission_id, graph_headers):
    """Fetch validation errors for a specific submission."""
    url = f"{GRAPH_BASE}/submissions/{submission_id}/validations{GRAPH_API_VER}"
    data = safe_get(url, graph_headers, f"validations {submission_id}")
    # Handle both response shapes
    if "value" in data:
        return data["value"]
    if "validations" in data:
        return data["validations"]
    # Sometimes the validations are at the root level as a list
    if isinstance(data, list):
        return data
    return []


def is_cve_related(text):
    tl = text.lower()
    return any(kw in tl for kw in CVE_KEYWORDS)


def extract_text(v):
    """Pull any human-readable text out of a validation object."""
    parts = []
    for key in ("message", "description", "details", "code", "errorCode", "title"):
        val = v.get(key)
        if val and isinstance(val, str):
            parts.append(val)
        elif val and isinstance(val, dict):
            parts.append(json.dumps(val))
    return " | ".join(parts)


def scan_product(product_id, product_name, graph_headers):
    result = {
        "product": product_name,
        "product_id": product_id,
        "submissions_scanned": 0,
        "cve_submissions": [],
        "other_failed_submissions": [],
        "needs_cve_update": False,
        "partner_center_base_url": f"https://partner.microsoft.com/en-us/dashboard/commercial-marketplace/offers/{product_id}",
    }

    submissions = list_submissions(product_id, graph_headers)
    result["submissions_scanned"] = len(submissions)

    for sub in submissions:
        sub_id = sub.get("id", "")
        state = sub.get("state", "")
        created = sub.get("createdDateTime", "N/A")
        report_url = f"https://partner.microsoft.com/en-us/dashboard/commercial-marketplace/offers/{product_id}/certification/reports/{sub_id}"

        validations = get_validations(sub_id, graph_headers)

        cve_issues = []
        other_issues = []
        for v in validations:
            text = extract_text(v)
            severity = v.get("severity", v.get("level", "unknown"))
            code = v.get("code", v.get("errorCode", "N/A"))
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
    failed_other = [f for f in findings if f["other_failed_submissions"] and not f["needs_cve_update"]]
    clean = [f for f in findings if not f["needs_cve_update"] and not f["other_failed_submissions"]]

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
                    print(f"      [{issue['severity'].upper()}] {issue['code']}: {issue['message'][:200]}")
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
                    print(f"      [{issue['severity'].upper()}] {issue['code']}: {issue['message'][:150]}")
    else:
        print("  ✅  None.")

    print(f"\n🟢  CLEAN  ({len(clean)} offer(s))")
    print("-" * 72)
    for f in clean:
        subs = f["submissions_scanned"]
        print(f"  ✅  {f['product']}  ({subs} submission(s) scanned — no CVE issues)")

    print("\n" + "=" * 72)

    # GitHub Actions annotations
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
    graph_token = get_token(client_id, tenant_id, client_secret, "https://graph.microsoft.com/.default")
    graph_headers = {"Authorization": f"Bearer {graph_token}", "Content-Type": "application/json"}
    print("✅ Graph API authenticated.")

    print("Authenticating to Partner Center API...")
    pc_token = get_token(client_id, tenant_id, client_secret, PC_SCOPE)
    pc_headers = {"Authorization": f"Bearer {pc_token}", "Content-Type": "application/json"}
    print("✅ Partner Center API authenticated.\n")

    print("Discovering all Partner Center offers...")
    products = list_all_products(pc_headers)
    if not products:
        print("[WARN] No products returned. Check SP role (must be 'Developer' in Commercial Marketplace).")
        sys.exit(0)

    print(f"  Found {len(products)} offer(s):\n")
    for p in products:
        pid = p.get("id", "").replace("product/", "")
        pname = p.get("name", p.get("externalId", pid))
        print(f"    • {pname}  [{pid}]")

    print(f"\nScanning submission history for all {len(products)} offer(s)...\n")

    findings = []
    for p in products:
        pid = p.get("id", "").replace("product/", "")
        pname = p.get("name", p.get("externalId", pid))
        print(f"  → {pname}  [{pid}]")
        result = scan_product(pid, pname, graph_headers)
        findings.append(result)
        print(f"       {result['submissions_scanned']} submission(s) scanned  |  "
              f"CVE: {'⚠️ YES' if result['needs_cve_update'] else '✅ clean'}")

    print_report(findings)

    out_path = os.path.join(os.environ.get("GITHUB_WORKSPACE", "/tmp"), "certification_full_scan.json")
    with open(out_path, "w") as fh:
        json.dump(findings, fh, indent=2)
    print(f"\n📄 Full JSON report: {out_path}")


if __name__ == "__main__":
    main()
