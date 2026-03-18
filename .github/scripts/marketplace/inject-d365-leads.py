#!/usr/bin/env python3
"""
inject-d365-leads.py
Wires all accessible Partner Center offers to a Dynamics 365 Customer Engagement
org as the customer-leads destination via the Microsoft Graph Product-Ingestion API.

Usage:
  # Uses credentials from environment or /tmp/d365-lead-injector.env
  python3 inject-d365-leads.py [--dry-run] [--offer-id <externalId>]

Required env vars:
  D365_CLIENT_ID      App Registration (pc-lead-injector) App ID
  D365_CLIENT_SECRET  Client secret
  D365_TENANT_ID      Azure AD tenant ID
  D365_ORG_URL        e.g. https://orgf3228985.crm.dynamics.com
"""

import os, sys, json, time, argparse, requests, msal

BASE_URL = "https://graph.microsoft.com/rp/product-ingestion"
API_VER  = "2022-03-01-preview2"

D365_ORG_URL   = os.getenv("D365_ORG_URL",   "https://orgf3228985.crm.dynamics.com")
D365_CLIENT_ID = os.getenv("D365_CLIENT_ID",  "019f327a-01e5-4a77-b960-7ebc2c6187f1")
D365_TENANT_ID = os.getenv("D365_TENANT_ID",  "a42a9fb4-e76a-4b34-b070-3bf3687022f0")

def load_env_file(path="/tmp/d365-lead-injector.env"):
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    os.environ.setdefault(k.strip(), v.strip())

def get_graph_token():
    app = msal.ConfidentialClientApplication(
        os.environ["AZURE_CLIENT_ID"],
        authority=f"https://login.microsoftonline.com/{os.environ['AZURE_TENANT_ID']}",
        client_credential=os.environ["AZURE_CLIENT_SECRET"],
    )
    r = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in r:
        print(f"[ERROR] Graph auth failed: {r.get('error_description')}", file=sys.stderr)
        sys.exit(1)
    return r["access_token"]

def graph_headers(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def get_all_products(h, offer_filter=None):
    products = []
    url = f"{BASE_URL}/product?api-version={API_VER}"
    while url:
        r = requests.get(url, headers=h, timeout=20)
        if r.status_code != 200:
            print(f"[WARN] GET /product: {r.status_code}")
            break
        data = r.json()
        for p in data.get("value", []):
            ext_id = p.get("identity", {}).get("externalId", "")
            if offer_filter and ext_id != offer_filter:
                continue
            # Skip consulting services - they don't have lead config
            if p.get("type") in ("consultingService",):
                continue
            products.append(p)
        url = data.get("@nextLink")
    return products

def get_resource_tree(h, product_guid):
    r = requests.get(
        f"{BASE_URL}/resource-tree/product/{product_guid}?api-version={API_VER}",
        headers=h, timeout=20
    )
    return r.json().get("resources", []) if r.status_code == 200 else []

def find_customer_leads_resource(resources):
    for r in resources:
        schema = r.get("$schema", "")
        if "customer-leads" in schema or "lead" in schema.lower():
            return r
    return None

def build_d365_leads_resource(product_id, org_url, client_id, client_secret, tenant_id):
    return {
        "$schema": "https://schema.mp.microsoft.com/schema/customer-leads/2022-03-01-preview3",
        "id": f"customer-leads/product/{product_id}",
        "destinationType": "dynamics365ForCustomerEngagement",
        "dynamics365ForCustomerEngagement": {
            "instanceUrl": org_url,
            "applicationId": client_id,
            "applicationSecret": client_secret,
            "directoryId": tenant_id,
            "contactEmail": ""
        }
    }

def poll_job(h, job_id):
    for _ in range(20):
        time.sleep(4)
        r = requests.get(f"{BASE_URL}/configure/{job_id}/status?api-version={API_VER}", headers=h, timeout=10)
        s = r.json().get("jobStatus", "").lower()
        if s in ("completed", "succeeded"):
            return True, None
        if s == "failed":
            return False, r.json().get("errors", [])
    return None, "timeout"

def configure(h, resources, dry_run=False):
    payload = {
        "$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
        "resources": resources
    }
    if dry_run:
        print(f"    [DRY-RUN] Would POST /configure with {len(resources)} resource(s)")
        return None, None
    r = requests.post(f"{BASE_URL}/configure?api-version={API_VER}", headers=h, json=payload, timeout=30)
    if r.status_code not in (200, 202):
        return False, f"HTTP {r.status_code}: {r.text[:300]}"
    job_id = r.json().get("jobId")
    return poll_job(h, job_id)

def main():
    load_env_file()
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--offer-id", help="Only this offer's externalId")
    parser.add_argument("--org-url", default=D365_ORG_URL)
    parser.add_argument("--client-id", default=D365_CLIENT_ID, dest="client_id")
    parser.add_argument("--tenant-id", default=D365_TENANT_ID, dest="tenant_id")
    args = parser.parse_args()

    client_secret = os.environ.get("D365_CLIENT_SECRET", "")
    if not client_secret:
        print("[ERROR] D365_CLIENT_SECRET not set", file=sys.stderr)
        sys.exit(1)

    dry_run = args.dry_run
    if dry_run:
        print("=== DRY RUN — no changes will be written ===\n")

    token = get_graph_token()
    h = graph_headers(token)

    print(f"Fetching all offers...")
    products = get_all_products(h, offer_filter=args.offer_id)
    print(f"Found {len(products)} offer(s).\n")

    updated = skipped = errors = 0

    for p in products:
        pid    = p.get("id", "").split("/")[-1]
        ext_id = p.get("identity", {}).get("externalId", "?")
        alias  = p.get("alias", "?")
        print(f"▶ [{ext_id}] {alias}")

        resources = get_resource_tree(h, pid)
        existing  = find_customer_leads_resource(resources)

        if existing:
            dest = existing.get("dynamics365ForCustomerEngagement", {}).get("instanceUrl", "")
            if dest == args.org_url:
                print(f"  ✅ Already wired to {args.org_url}\n")
                skipped += 1
                continue
            print(f"  ⚠️  Currently wired to: {dest or 'different destination'} — replacing")

        leads_resource = build_d365_leads_resource(
            pid, args.org_url, args.client_id, client_secret, args.tenant_id
        )
        if existing:
            leads_resource["id"] = existing.get("id", leads_resource["id"])

        ok, err = configure(h, [leads_resource], dry_run)
        if ok is True:
            print(f"  ✅ Wired to D365 ({args.org_url})\n")
            updated += 1
        elif ok is False:
            print(f"  ❌ Failed: {err}\n")
            errors += 1
        # None = dry-run

    print("=" * 50)
    print(f"Updated: {updated}  Skipped: {skipped}  Errors: {errors}")
    if dry_run:
        print("(DRY RUN — nothing written)")

if __name__ == "__main__":
    main()
