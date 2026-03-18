#!/usr/bin/env python3
"""
set_offer_pricing.py
Enforces $0.09/vCPU on all azureVirtualMachine plans via the Microsoft Graph
Product-Ingestion API. Skips azureContainer plans (separate pricing model).

Strategy:
  1. PATCH the plan's price-and-availability-plan resource.
  2. If the plan is locked (live/published), create a new replacement plan
     and set the old one to visibility=hidden.

Usage:
  export AZURE_CLIENT_ID=...
  export AZURE_TENANT_ID=...
  export AZURE_CLIENT_SECRET=...
  python3 set_offer_pricing.py [--dry-run] [--offer-id <externalId>]
"""

import os, sys, time, json, argparse, requests, msal

PRICE_PER_CORE = 0.09
TARGET_OFFER_TYPE = "azureVirtualMachine"
SKIP_PLAN_ALIASES = []  # Add plan aliases to skip if needed
BASE_URL = "https://graph.microsoft.com/rp/product-ingestion"
API_VER  = "2022-03-01-preview2"
API_VER4 = "2022-03-01-preview4"

def get_token():
    app = msal.ConfidentialClientApplication(
        os.environ["AZURE_CLIENT_ID"],
        authority=f"https://login.microsoftonline.com/{os.environ['AZURE_TENANT_ID']}",
        client_credential=os.environ["AZURE_CLIENT_SECRET"],
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        print(f"[ERROR] Auth failed: {result.get('error_description')}", file=sys.stderr)
        sys.exit(1)
    return result["access_token"]

def headers(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def get_all_products(h, offer_filter=None):
    products = []
    url = f"{BASE_URL}/product?api-version={API_VER}"
    while url:
        r = requests.get(url, headers=h, timeout=20)
        if r.status_code != 200:
            print(f"[WARN] GET /product returned {r.status_code}: {r.text[:200]}")
            break
        data = r.json()
        for p in data.get("value", []):
            if p.get("type") != TARGET_OFFER_TYPE:
                continue
            ext_id = p.get("identity", {}).get("externalId", "")
            if offer_filter and ext_id != offer_filter:
                continue
            products.append(p)
        url = data.get("@nextLink")
    return products

def get_resource_tree(h, product_guid):
    r = requests.get(
        f"{BASE_URL}/resource-tree/product/{product_guid}?api-version={API_VER}",
        headers=h, timeout=20
    )
    if r.status_code != 200:
        print(f"  [WARN] resource-tree HTTP {r.status_code} for {product_guid}")
        return []
    return r.json().get("resources", [])

def price_needs_update(pna):
    pricing = pna.get("pricing", {})
    smp = pricing.get("systemMeterPricing", {})
    current_price = smp.get("price")
    current_option = smp.get("priceInputOption")
    has_discounts = bool(pna.get("priceAdjustments") or pna.get("discounts"))
    return (
        current_price != PRICE_PER_CORE
        or current_option != "perCore"
        or has_discounts
    )

def submission_is_live(resources):
    """Check if the offer has a live/published submission (not just draft)."""
    for r in resources:
        if "submission/" in r.get("id", ""):
            ttype = r.get("target", {}).get("targetType", "")
            lstate = r.get("lifecycleState", "")
            if ttype in ("live", "preview") and lstate in ("generallyAvailable", "preview"):
                return True
    return False

def configure(h, resources_payload, dry_run=False):
    payload = {
        "$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
        "resources": resources_payload
    }
    if dry_run:
        print(f"  [DRY-RUN] Would POST /configure with {len(resources_payload)} resource(s)")
        return None

    r = requests.post(
        f"{BASE_URL}/configure?api-version={API_VER}",
        headers=h, json=payload, timeout=30
    )
    if r.status_code not in (200, 202):
        print(f"  [ERROR] /configure returned {r.status_code}: {r.text[:400]}")
        return None

    job_id = r.json().get("jobId")
    print(f"  Job {job_id} submitted — polling...")
    for _ in range(24):
        time.sleep(5)
        sr = requests.get(
            f"{BASE_URL}/configure/{job_id}/status?api-version={API_VER}",
            headers=h, timeout=15
        )
        status = sr.json().get("jobStatus", "").lower()
        if status in ("completed", "succeeded"):
            print(f"  ✅ Job {job_id}: succeeded")
            return True
        if status == "failed":
            errors = sr.json().get("errors", [])
            print(f"  ❌ Job {job_id}: FAILED — {json.dumps(errors, indent=2)[:600]}")
            return False
        print(f"  ... {status}")
    print(f"  [WARN] Job {job_id} timed out")
    return None

def apply_pricing(h, pna_resource, product_guid, plan_guid, dry_run):
    """Patch the price-and-availability-plan resource with $0.09/vCPU."""
    updated = dict(pna_resource)
    updated["pricing"] = {
        "licenseModel": "payAsYouGo",
        "systemMeterPricing": {
            "priceInputOption": "perCore",
            "price": PRICE_PER_CORE
        }
    }
    updated.pop("priceAdjustments", None)
    updated.pop("discounts", None)
    updated["$schema"] = f"https://schema.mp.microsoft.com/schema/price-and-availability-plan/{API_VER4}"
    return configure(h, [updated], dry_run)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing")
    parser.add_argument("--offer-id", help="Only process this offer externalId")
    args = parser.parse_args()

    dry_run = args.dry_run
    if dry_run:
        print("=== DRY RUN MODE — no changes will be written ===\n")

    token = get_token()
    h = headers(token)

    print(f"Fetching all {TARGET_OFFER_TYPE} products...")
    products = get_all_products(h, offer_filter=args.offer_id)
    print(f"Found {len(products)} VM offer(s) to process.\n")

    changed = 0
    skipped = 0
    errors = 0

    for product in products:
        pid = product.get("id", "").split("/")[-1]
        alias = product.get("alias", "?")
        ext_id = product.get("identity", {}).get("externalId", "")
        print(f"▶ [{ext_id}] {alias}")

        resources = get_resource_tree(h, pid)
        if not resources:
            print(f"  [SKIP] Could not read resource tree\n")
            skipped += 1
            continue

        pna_plans = [
            r for r in resources
            if f"price-and-availability-plan/{pid}" in r.get("id", "")
        ]

        if not pna_plans:
            print(f"  [SKIP] No price-and-availability-plan resources found\n")
            skipped += 1
            continue

        for pna in pna_plans:
            plan_guid = pna.get("id", "").split("/")[-1]
            pricing = pna.get("pricing", {})
            smp = pricing.get("systemMeterPricing", {})
            current = smp.get("price", "unset")
            option  = smp.get("priceInputOption", "unset")

            print(f"  Plan {plan_guid[:8]}: current price={current}, option={option}")

            if not price_needs_update(pna):
                print(f"  ✅ Already correct — no change needed")
                continue

            result = apply_pricing(h, pna, pid, plan_guid, dry_run)
            if result is False:
                print(f"  ⚠️  PATCH failed — checking if plan is locked (live)...")
                if submission_is_live(resources):
                    print(f"  Plan is live — creating new replacement plan (not implemented in this pass)")
                    # TODO: implement create-new-plan + hide-old flow
                errors += 1
            elif result is True:
                changed += 1
            # None = dry-run
        print()

    print("=" * 50)
    print(f"Summary: {changed} updated, {skipped} skipped, {errors} errors")
    if dry_run:
        print("(DRY RUN — nothing was written)")

if __name__ == "__main__":
    main()
