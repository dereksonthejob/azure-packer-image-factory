#!/usr/bin/env python3
"""
inject-d365-leads.py
Wires the Dynamics 365 Customer Engagement lead destination to all
azureVirtualMachine and azureContainer offers via the Microsoft Graph
Product-Ingestion API.

Usage:
  export AZURE_CLIENT_ID=...
  export AZURE_TENANT_ID=...
  export AZURE_CLIENT_SECRET=...

  python3 inject-d365-leads.py \\
    --d365-org-url https://org12345.crm.dynamics.com \\
    --d365-client-id <app-reg-client-id> \\
    --d365-client-secret <app-reg-secret> \\
    [--dry-run] \\
    [--offer-id <externalId>]

Pre-requisites:
  1. D365 CE org provisioned (sandbox or production)
  2. An App Registration in the D365 tenant with:
       - Dynamics CRM user_impersonation permission
       - A D365 user account with System Administrator role
  3. Partner Center SP credentials in env vars above
"""

import os, sys, json, time, argparse, requests, msal

BASE_URL = "https://graph.microsoft.com/rp/product-ingestion"
API_VER  = "2022-03-01-preview2"

LEAD_SCHEMA = "https://schema.mp.microsoft.com/schema/customer-leads/2022-03-01-preview3"

def get_pc_token():
    """Get a token for the Product Ingestion API using SP credentials."""
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
            print(f"[WARN] GET /product returned {r.status_code}")
            break
        data = r.json()
        for p in data.get("value", []):
            if p.get("type") not in ("azureVirtualMachine", "azureContainer"):
                continue
            if offer_filter and p.get("identity", {}).get("externalId") != offer_filter:
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
        return []
    return r.json().get("resources", [])

def build_d365_leads_resource(product_id, org_url, client_id, client_secret):
    """Build the customer-leads resource payload for D365 Customer Engagement."""
    return {
        "$schema": LEAD_SCHEMA,
        "product": {"externalId": product_id},
        "leadDestination": "dynamics365ForCustomerEngagement",
        "dynamics365ForCustomerEngagement": {
            "instanceUrl": org_url.rstrip("/"),
            "contactEmail": "",           # Optional: email for lead notifications
            "authenticationKey": {
                "clientId": client_id,
                "clientSecret": client_secret
            }
        }
    }

def configure(h, resources_payload, dry_run=False):
    payload = {
        "$schema": f"https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
        "resources": resources_payload
    }
    if dry_run:
        print(f"  [DRY-RUN] Would POST /configure with customer-leads payload")
        print(f"  {json.dumps(resources_payload[0], indent=4)[:400]}")
        return True

    r = requests.post(
        f"{BASE_URL}/configure?api-version={API_VER}",
        headers=h, json=payload, timeout=30
    )
    if r.status_code not in (200, 202):
        print(f"  [ERROR] /configure returned {r.status_code}: {r.text[:400]}")
        return False

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
            print(f"  ❌ Job {job_id}: FAILED — {json.dumps(errors)[:600]}")
            return False
        print(f"  ... {status}")
    print(f"  [WARN] Job {job_id} timed out")
    return False

def find_existing_leads_resource(resources):
    """Find existing customer-leads resource if already wired."""
    for r in resources:
        if "customer-leads" in r.get("$schema", "") or "customer-leads" in r.get("id", ""):
            return r
    return None

def main():
    parser = argparse.ArgumentParser(description="Wire D365 CE lead destination to all Marketplace offers")
    parser.add_argument("--d365-org-url", required=True, help="D365 CE org URL e.g. https://org12345.crm.dynamics.com")
    parser.add_argument("--d365-client-id", required=True, help="App Registration client ID in D365 tenant")
    parser.add_argument("--d365-client-secret", required=True, help="App Registration client secret")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing")
    parser.add_argument("--offer-id", help="Only process this offer externalId")
    args = parser.parse_args()

    if args.dry_run:
        print("=== DRY RUN MODE — no changes will be written ===\n")

    token = get_pc_token()
    h = headers(token)

    print("Fetching all VM and Container offers...")
    products = get_all_products(h, offer_filter=args.offer_id)
    print(f"Found {len(products)} offer(s) to wire.\n")

    updated = 0
    skipped = 0
    errors  = 0

    for product in products:
        ext_id = product.get("identity", {}).get("externalId", "?")
        alias  = product.get("alias", "?")
        pid    = product.get("id", "").split("/")[-1]
        ptype  = product.get("type", "?")
        print(f"▶ [{ext_id}] {alias} ({ptype})")

        resources = get_resource_tree(h, pid)
        existing  = find_existing_leads_resource(resources)

        if existing:
            dest = existing.get("leadDestination", "unknown")
            inst = existing.get("dynamics365ForCustomerEngagement", {}).get("instanceUrl", "")
            if inst == args.d365_org_url.rstrip("/"):
                print(f"  ✅ Already wired to {inst} — skipping")
                skipped += 1
                print()
                continue
            print(f"  ℹ️  Currently wired to '{dest}' ({inst}) — updating to new org URL")

        leads_resource = build_d365_leads_resource(
            ext_id,
            args.d365_org_url,
            args.d365_client_id,
            args.d365_client_secret
        )

        ok = configure(h, [leads_resource], dry_run=args.dry_run)
        if ok:
            updated += 1
        else:
            errors += 1
        print()

    print("=" * 50)
    print(f"Summary: {updated} wired, {skipped} already correct, {errors} errors")
    if args.dry_run:
        print("(DRY RUN — nothing was written)")

if __name__ == "__main__":
    main()
