import requests
import msal
import json
import os
import sys
from datetime import datetime

# ============================================================================
# certification_report_scan.py
# Scans the most recent certification submission for every Partner Center offer
# and flags any failures related to CVEs / security / outdated packages.
# Outputs a structured summary to stdout (captured as GitHub Actions job log).
# ============================================================================

CVE_KEYWORDS = [
    "cve", "vulnerability", "vulnerabilities", "security update",
    "outdated", "patch", "kernel", "out-of-date", "critical update",
    "security advisory", "unpatched", "exploit", "exposure"
]

# Known product IDs (GUID-based offers)
KNOWN_PRODUCTS = {
    "8a9b1fd3-aef8-44dc-a088-14d4ae49417a": "SQL Server Portfolio (2019 & 2022)",
    "a3f416b8-79d6-4899-b3b4-1244423c3ec4": "Windows 10 Desktop",
    "e19e298c-d651-4176-a930-1deedcdb4c3e": "Windows 11 Desktop",
}

# ExternalId-based offers (Ubuntu, Kali, RHEL) — resolved to real product GUIDs at runtime
EXTERNAL_ID_PRODUCTS = [
    "ubuntu-server-gen2",
    "kali-linux-security-gen2",
    "rhel-enterprise-gen2",
]


def get_token(client_id, tenant_id, client_secret, scope):
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.ConfidentialClientApplication(client_id, authority=authority, client_credential=client_secret)
    result = app.acquire_token_for_client(scopes=[scope])
    if "access_token" not in result:
        print(f"[AUTH ERROR] Failed to get token for scope {scope}: {result.get('error_description')}")
        sys.exit(1)
    return result["access_token"]


def resolve_external_id_to_guid(external_id, headers):
    """Resolve an externalId string (e.g. 'ubuntu-server-gen2') to its internal product GUID."""
    url = f"https://graph.microsoft.com/rp/product-ingestion/product?externalId={external_id}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code == 200:
        data = r.json()
        # The product ID is returned as e.g. "product/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        pid = data.get("id", "").replace("product/", "")
        name = data.get("name", external_id)
        return pid, name
    return None, external_id


def get_submissions(product_id, headers):
    """Return list of submissions for a product, newest first."""
    url = f"https://graph.microsoft.com/rp/product-ingestion/submissions?product=product/{product_id}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code != 200:
        return []
    return r.json().get("value", [])


def get_validations(submission_id, headers):
    """Fetch validation/certification errors for a specific submission."""
    url = f"https://graph.microsoft.com/rp/product-ingestion/submissions/{submission_id}/validations"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code != 200:
        return []
    return r.json().get("value", r.json().get("validations", []))


def is_cve_related(text):
    """Return True if the text mentions CVE / security / outdated package keywords."""
    text_lower = text.lower()
    return any(kw in text_lower for kw in CVE_KEYWORDS)


def scan_product(product_id, product_name, headers):
    """
    Scan the most recent failed submission of a product.
    Returns a dict with findings or None if no failures found.
    """
    submissions = get_submissions(product_id, headers)
    if not submissions:
        return {"product": product_name, "product_id": product_id, "status": "NO_SUBMISSIONS", "cve_issues": []}

    # Sort by createdDateTime descending, take the most recent failed one
    # Also check the most recent ANY submission to show current state
    submissions_sorted = sorted(
        submissions,
        key=lambda s: s.get("createdDateTime", ""),
        reverse=True
    )
    latest = submissions_sorted[0]
    latest_state = latest.get("state", "unknown")

    # Find most recent failed submission for CVE report
    failed = next(
        (s for s in submissions_sorted if "fail" in s.get("state", "").lower() or "certif" in s.get("state", "").lower()),
        None
    )

    result = {
        "product": product_name,
        "product_id": product_id,
        "current_state": latest_state,
        "latest_submission_id": latest.get("id", "N/A"),
        "partner_center_url": f"https://partner.microsoft.com/en-us/dashboard/commercial-marketplace/offers/{product_id}/certification/reports/{latest.get('id','')}",
        "cve_issues": [],
        "all_issues": [],
        "needs_cve_update": False,
    }

    if not failed:
        result["status"] = "CLEAN"
        return result

    result["failed_submission_id"] = failed.get("id")
    result["failed_submission_state"] = failed.get("state")
    result["failed_at"] = failed.get("createdDateTime", "N/A")

    validations = get_validations(failed["id"], headers)
    for v in validations:
        msg = v.get("message", "") or v.get("description", "") or str(v)
        severity = v.get("severity", v.get("level", "unknown"))
        code = v.get("code", v.get("errorCode", "N/A"))
        issue = {"code": code, "severity": severity, "message": msg}
        result["all_issues"].append(issue)
        if is_cve_related(msg):
            result["cve_issues"].append(issue)
            result["needs_cve_update"] = True

    result["status"] = "CVE_REQUIRED" if result["needs_cve_update"] else "FAILED_OTHER"
    return result


def print_report(findings):
    """Print a clean human-readable summary to stdout."""
    print("\n" + "=" * 70)
    print("  PARTNER CENTER CERTIFICATION REPORT — CVE SCAN")
    print(f"  Run at: {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}")
    print("=" * 70)

    cve_offers = [f for f in findings if f.get("needs_cve_update")]
    other_failed = [f for f in findings if f.get("status") == "FAILED_OTHER"]
    clean = [f for f in findings if f.get("status") in ("CLEAN", "NO_SUBMISSIONS")]

    print(f"\n🔴 NEEDS CVE UPDATE ({len(cve_offers)} offers):")
    if cve_offers:
        for f in cve_offers:
            print(f"\n  📦 {f['product']}  [{f['product_id']}]")
            print(f"     State      : {f.get('failed_submission_state','N/A')}")
            print(f"     Failed at  : {f.get('failed_at','N/A')}")
            print(f"     Report URL : {f['partner_center_url']}")
            print(f"     CVE Issues ({len(f['cve_issues'])}):")
            for issue in f["cve_issues"]:
                print(f"       [{issue['severity'].upper()}] {issue['code']}: {issue['message'][:200]}")
    else:
        print("  ✅ None — no CVE-related failures detected.")

    print(f"\n🟡 FAILED (Other Reasons) ({len(other_failed)} offers):")
    if other_failed:
        for f in other_failed:
            print(f"\n  📦 {f['product']}  [{f['product_id']}]")
            print(f"     State      : {f.get('current_state','N/A')}")
            print(f"     Report URL : {f['partner_center_url']}")
            for issue in f.get("all_issues", [])[:3]:  # show max 3
                print(f"       [{issue['severity'].upper()}] {issue['code']}: {issue['message'][:200]}")
    else:
        print("  ✅ None.")

    print(f"\n🟢 CLEAN / NO ISSUES ({len(clean)} offers):")
    for f in clean:
        print(f"  ✅ {f['product']}  [State: {f.get('current_state','N/A')}]")

    print("\n" + "=" * 70)

    # GitHub Actions summary output (set-output style for workflow steps)
    cve_offer_names = ", ".join(f["product"] for f in cve_offers) or "None"
    print(f"\n::notice title=CVE Scan Result::Offers needing CVE updates: {cve_offer_names}")
    if cve_offers:
        print("::error title=CVE Updates Required::One or more marketplace offers failed certification due to CVE/security issues. Rebuild required.")
        sys.exit(1)  # Fail the workflow step so it's visible in GitHub Actions


def main():
    client_id = os.environ.get("AZURE_CLIENT_ID")
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")

    if not all([client_id, tenant_id, client_secret]):
        print("[ERROR] Missing AZURE_CLIENT_ID, AZURE_TENANT_ID, or AZURE_CLIENT_SECRET environment variables.")
        sys.exit(1)

    print("Authenticating to Microsoft Graph API...")
    token = get_token(client_id, tenant_id, client_secret, "https://graph.microsoft.com/.default")
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    print("✅ Authenticated.\n")

    all_products = dict(KNOWN_PRODUCTS)

    # Resolve externalId-based products to real GUIDs
    for ext_id in EXTERNAL_ID_PRODUCTS:
        guid, name = resolve_external_id_to_guid(ext_id, headers)
        if guid:
            all_products[guid] = name
            print(f"  Resolved externalId '{ext_id}' → {guid} ({name})")
        else:
            print(f"  [WARN] Could not resolve externalId: {ext_id} — skipping.")

    print(f"\nScanning {len(all_products)} offers for certification failures...\n")

    findings = []
    for product_id, product_name in all_products.items():
        print(f"  → Scanning: {product_name} [{product_id}]")
        result = scan_product(product_id, product_name, headers)
        findings.append(result)

    print_report(findings)

    # Write raw JSON report as artifact
    report_path = os.environ.get("GITHUB_WORKSPACE", "/tmp") + "/certification_scan_report.json"
    with open(report_path, "w") as f:
        json.dump(findings, f, indent=2)
    print(f"\n📄 Full JSON report written to: {report_path}")


if __name__ == "__main__":
    main()
