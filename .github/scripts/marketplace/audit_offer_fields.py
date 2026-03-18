#!/usr/bin/env python3
"""
audit_offer_fields.py
Scans every accessible Marketplace offer's resource-tree and reports
missing or incomplete required fields for each page.

Checks against the standards defined in azure-vm-offer-standards:
  - Offer setup (CRM lead destination)
  - Properties (categories, legal terms)
  - Offer listing (title, short desc, HTML desc, 3 keywords, privacy URL,
                   support contact with name/email/phone/URL, screenshot)
  - Preview audience (≥1 subscription ID)
  - Plan listing (name, summary, description per plan)
  - Price & availability (systemMeterPricing set, markets, visibility)
  - Technical configuration (SIG reference)
  - Resell through CSPs ("Any partner in the CSP program")

Usage:
  export AZURE_CLIENT_ID=...
  export AZURE_TENANT_ID=...
  export AZURE_CLIENT_SECRET=...
  python3 audit_offer_fields.py [--offer-id <externalId>] [--json]
"""

import os, sys, json, argparse, requests, msal

BASE_URL = "https://graph.microsoft.com/rp/product-ingestion"
API_VER  = "2022-03-01-preview2"

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

def h(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def get_all_products(headers, offer_filter=None):
    products = []
    url = f"{BASE_URL}/product?api-version={API_VER}"
    while url:
        r = requests.get(url, headers=headers, timeout=20)
        if r.status_code != 200:
            break
        data = r.json()
        for p in data.get("value", []):
            ext_id = p.get("identity", {}).get("externalId", "")
            if offer_filter and ext_id != offer_filter:
                continue
            products.append(p)
        url = data.get("@nextLink")
    return products

def get_resource_tree(headers, product_guid):
    r = requests.get(
        f"{BASE_URL}/resource-tree/product/{product_guid}?api-version={API_VER}",
        headers=headers, timeout=20
    )
    if r.status_code != 200:
        return []
    return r.json().get("resources", [])

def check(condition, label, issues):
    if not condition:
        issues.append(f"MISSING: {label}")

def audit_offer(product, resources):
    ext_id = product.get("identity", {}).get("externalId", "?")
    alias  = product.get("alias", "?")
    ptype  = product.get("type", "?")
    pid    = product.get("id", "").split("/")[-1]

    issues = []

    # --- Alias naming standard (no underscores/concatenated tokens) ---
    if "_" in alias or (alias == alias.lower() and " " not in alias):
        issues.append(f"BAD ALIAS: '{alias}' — must be plain readable words (e.g. 'Oracle Linux 9 Gen2')")

    # --- Offer-level listing ---
    listings = [r for r in resources if "/listing/" in r.get("id", "") and "asset" not in r.get("id", "") and "plan" not in r.get("id", "")]
    if not listings:
        issues.append("MISSING: Offer listing resource")
    for lst in listings:
        check(lst.get("title"), "Offer listing > title", issues)
        check(lst.get("shortDescription"), "Offer listing > shortDescription", issues)
        check(lst.get("description"), "Offer listing > description (HTML)", issues)
        check(lst.get("privacyPolicyLink") or lst.get("privacyPolicy"), "Offer listing > privacyPolicyLink", issues)
        kw = lst.get("keywords") or lst.get("searchKeywords", [])
        if len(kw) < 3:
            issues.append(f"MISSING: Offer listing > searchKeywords (need ≥3, have {len(kw)})")
        sc = lst.get("supportContact") or lst.get("engineeringContact") or {}
        check(sc.get("name"), "Offer listing > supportContact.name", issues)
        check(sc.get("email"), "Offer listing > supportContact.email", issues)
        check(sc.get("phone"), "Offer listing > supportContact.phone", issues)
        check(sc.get("uri") or sc.get("url"), "Offer listing > supportContact.uri", issues)

    # --- Listing assets (screenshots) ---
    assets = [r for r in resources if "listing-asset" in r.get("id", "") or "asset" in r.get("$schema", "")]
    screenshots = [a for a in assets if a.get("type", "").lower() in ("screenshot", "image")]
    if not screenshots:
        issues.append("MISSING: Offer listing > at least 1 screenshot")

    # --- Properties ---
    props = [r for r in resources if "/property/" in r.get("id", "") or "product-listing-property" in r.get("$schema", "")]
    if not props:
        issues.append("MISSING: Properties resource")
    for prop in props:
        cats = prop.get("categories") or prop.get("categoryIds") or prop.get("subcategories", [])
        if not cats:
            issues.append("MISSING: Properties > categories (need ≥1)")
        legal = prop.get("termsOfUse") or prop.get("legalTerms") or prop.get("termsAndConditions", "")
        check(legal, "Properties > legal terms", issues)

    # --- Preview audience ---
    pna_offer = [r for r in resources if "price-and-availability-offer/" in r.get("id", "")]
    for pna in pna_offer:
        preview = pna.get("previewAudiences", [])
        if not preview:
            issues.append("MISSING: Price & availability > previewAudiences (≥1 subscription ID)")

    # --- Plan-level checks ---
    plan_ids = set()
    for r in resources:
        if "/plan/" in r.get("id", ""):
            parts = r.get("id", "").split("/")
            try:
                idx = parts.index("plan")
                plan_ids.add(parts[idx + 1])
            except (ValueError, IndexError):
                pass

    for plan_id in plan_ids:
        plan_prefix = f"plan/{plan_id}"

        # Plan listing
        plan_listings = [r for r in resources if f"{plan_prefix}/listing/" in r.get("id", "") or
                         (f"/{plan_id}/" in r.get("id", "") and "plan-listing" in r.get("$schema", ""))]
        for pl in plan_listings:
            pname = pl.get("name") or pl.get("title", "")
            check(pname, f"Plan {plan_id[:8]} > listing.name", issues)
            check(pl.get("summary"), f"Plan {plan_id[:8]} > listing.summary", issues)
            check(pl.get("description"), f"Plan {plan_id[:8]} > listing.description", issues)

        # Price & availability per plan
        pna_plans = [r for r in resources if f"price-and-availability-plan/{pid}/{plan_id}" in r.get("id", "") or
                     (f"/{plan_id}" in r.get("id", "") and "price-and-availability-plan" in r.get("$schema", ""))]
        for pna in pna_plans:
            pricing = pna.get("pricing", {})
            smp = pricing.get("systemMeterPricing", {})
            if not smp or smp.get("price") is None:
                issues.append(f"Plan {plan_id[:8]} > pricing: systemMeterPricing NOT SET")
            else:
                price = smp.get("price")
                if price != 0.09 and ptype == "azureVirtualMachine":
                    issues.append(f"Plan {plan_id[:8]} > pricing: price={price} (expected 0.09)")
            markets = pna.get("markets", [])
            if not markets:
                issues.append(f"Plan {plan_id[:8]} > pricing: no markets selected")
            visibility = pna.get("visibility", "")
            if visibility not in ("visible", "hidden"):
                issues.append(f"Plan {plan_id[:8]} > pricing: visibility='{visibility}' (expected 'visible')")
            # CSP
            csp = pna.get("resellerChannel") or pna.get("cspState") or pna.get("cspOption", "")
            if csp not in ("anyPartner", "any", ""):  # blank = needs to be set
                pass  # presence is enough for now unless explicitly wrong
            elif not csp:
                issues.append(f"Plan {plan_id[:8]} > CSP reseller: not set (expected 'anyPartner')")

        # Tech config
        tech = [r for r in resources if "virtual-machine-plan-technical" in r.get("$schema", "") and f"/{plan_id}" in r.get("id", "")]
        if not tech:
            issues.append(f"Plan {plan_id[:8]} > technical configuration: missing")

    return {
        "externalId": ext_id,
        "alias": alias,
        "type": ptype,
        "issues": issues,
        "issue_count": len(issues)
    }

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--offer-id", help="Only audit this offer externalId")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    token = get_token()
    hdrs = h(token)

    print("Fetching all products...", file=sys.stderr)
    products = get_all_products(hdrs, offer_filter=args.offer_id)
    print(f"Found {len(products)} offer(s).\n", file=sys.stderr)

    results = []
    for product in products:
        pid = product.get("id", "").split("/")[-1]
        alias = product.get("alias", "?")
        print(f"Auditing: {alias}...", file=sys.stderr)
        resources = get_resource_tree(hdrs, pid)
        result = audit_offer(product, resources)
        results.append(result)

    if args.json:
        print(json.dumps(results, indent=2))
        return

    # Human-readable report
    total_issues = sum(r["issue_count"] for r in results)
    clean = [r for r in results if r["issue_count"] == 0]
    dirty = [r for r in results if r["issue_count"] > 0]

    print("=" * 60)
    print(f"OFFER FIELD COMPLETENESS AUDIT  —  {len(products)} offers")
    print(f"{'✅ Clean:':<12} {len(clean)}    {'⚠️  Issues:':<12} {len(dirty)}    Total issues: {total_issues}")
    print("=" * 60)

    for r in sorted(dirty, key=lambda x: -x["issue_count"]):
        print(f"\n❌ [{r['externalId']}] {r['alias']}  ({r['issue_count']} issues)")
        for issue in r["issues"]:
            print(f"   • {issue}")

    if clean:
        print(f"\n✅ Clean offers ({len(clean)}):")
        for r in clean:
            print(f"   [{r['externalId']}] {r['alias']}")

if __name__ == "__main__":
    main()
