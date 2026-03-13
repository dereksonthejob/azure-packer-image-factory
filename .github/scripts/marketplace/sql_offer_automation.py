import requests
import json
import msal
import sys
import os

def main():
    print("Initiating Microsoft Partner Center SQL Server 2025 Automation...")

    # Load Authentication from GitHub Actions Environment Variables
    client_id = os.environ.get("AZURE_CLIENT_ID")
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")

    if not client_id or not tenant_id or not client_secret:
        print("Missing required API authentication variables.")
        return

    # Helper: Discover Latest ACG Version Autonomously
    authority = "https://login.microsoftonline.com/" + tenant_id
    def get_latest_gallery_version(img_def_target):
        mgmt_app = msal.ConfidentialClientApplication(client_id, authority=authority, client_credential=client_secret)
        mgmt_result = mgmt_app.acquire_token_for_client(scopes=["https://management.azure.com/.default"])
        if "access_token" not in mgmt_result:
            return "1.0.0"
            
        mgmt_headers = {"Authorization": f"Bearer {mgmt_result['access_token']}"}
        sub_id = "e2ba26ec-b676-47aa-ba30-f1c5c0ad0952"
        rg = "rg-acgpackerfactory-eastus"
        gallery = "acgpackerfactoryeastus"
        
        url = f"https://management.azure.com/subscriptions/{sub_id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{img_def_target}/versions?api-version=2024-03-03"
        resp = requests.get(url, headers=mgmt_headers, timeout=15)
        
        if resp.status_code == 200:
            versions = resp.json().get("value", [])
            if not versions:
                return "1.0.0"
            latest = sorted(versions, key=lambda x: x.get("name", "0.0.0"), reverse=True)[0]
            discovered_version = latest.get("name", "1.0.0")
            print(f"[{img_def_target}] Automatically bonded to Version: {discovered_version}")
            return discovered_version
        return "1.0.0"

    print("Authenticating to Microsoft Graph API...")
    app = msal.ConfidentialClientApplication(
        client_id, authority=authority,
        client_credential=client_secret
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    
    if "access_token" not in result:
        print("Failed to acquire MS Graph Token")
        sys.exit(1)

    token = result["access_token"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    
    # --- SQL SERVER 2025 MAPPING TOPOLOGY ---
    product_alias = "sql-server-2025-gen2"
    
    sql_plans = [
        ("plan-sql2025-ws2025-dev", "SQL Server 2025 Developer on Windows Server 2025", "imgdef-sql2025-ws2025-dev-gen2"),
        ("plan-sql2025-ws2025-ent", "SQL Server 2025 Enterprise on Windows Server 2025", "imgdef-sql2025-ws2025-ent-gen2"),
        ("plan-sql2025-ws2025-std", "SQL Server 2025 Standard on Windows Server 2025", "imgdef-sql2025-ws2025-std-gen2")
    ]
    
    resources = []
    
    print(f"Synthesizing the Unified SQL Server 2025 Root Offer ({product_alias})...")
    # 1. Product (Offer) Creation Shell
    resources.append({
        "$schema": "https://schema.mp.microsoft.com/schema/product/2022-03-01-preview3",
        "id": f"product/{product_alias}",
        "name": "SQL Server 2025",
        "kind": "azureVM"
    })
    
    # 2. Plan Minting Loop
    for p_id, p_name, img_def in sql_plans:
        # Core Plan structural node
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/plan/2022-03-01-preview2",
            "id": f"plan/{product_alias}/{p_id}",
            "product": f"product/{product_alias}",
            "name": p_name
        })
        
        # Plan Listing SEO configuration
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/plan-listing/2022-03-01-preview3",
            "id": f"plan-listing/{product_alias}/public/main/{p_id}/en-us",
            "product": f"product/{product_alias}",
            "plan": f"plan/{product_alias}/{p_id}",
            "kind": "azureVM-plan",
            "languageId": "en-us",
            "name": p_name,
            "summary": p_name,
            "description": f"<h2>{p_name}</h2><p>Experience enterprise-grade security and reliability with {p_name}. Optimized for Gen2 execution and high-performance transactional workloads.</p>"
        })
        
        # Hardware & Image Technical Configuration (Specifically tailored to SQL on Windows Server)
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/virtual-machine-plan-technical-configuration/2022-03-01-preview2",
            "id": f"virtual-machine-plan-technical-configuration/{product_alias}/{p_id}",
            "product": f"product/{product_alias}",
            "plan": f"plan/{product_alias}/{p_id}",
            "operatingSystemFamily": "Windows",
            "operatingSystem": "Windows", 
            "generation": "gen2",
            "state": "generalized",
            "securityType": "TrustedLaunch",
            "supportsAcceleratedNetworking": True,
            "supportsCloudInitConfiguration": False, # Windows does not natively support Cloud-init via canonical daemon
            "supportsVmExtensions": True,
            "supportsBackup": True,
            "supportsMicrosoftEntraIdentityAuthentication": True,
            "isNetworkVirtualAppliance": False,
            "recommendedSizes": [
                "Standard_D8s_v5",
                "Standard_D16s_v5",
                "Standard_E8s_v5",
                "Standard_E16s_v5",
                "Standard_M8ms",
                "Standard_M16ms"
            ],
            "azureComputeGalleryImageIdentities": [
                {
                    "subscriptionId": "e2ba26ec-b676-47aa-ba30-f1c5c0ad0952",  
                    "resourceGroup": "rg-acgpackerfactory-eastus",
                    "galleryName": "acgpackerfactoryeastus",
                    "imageDefinitionName": img_def,
                    "imageVersion": get_latest_gallery_version(img_def)
                }
            ]
        })
        
    payload = {
        "$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
        "resources": resources
    }
    
    cfg_url = "https://graph.microsoft.com/rp/product-ingestion/configure?api-version=2022-03-01-preview2"
    
    print(f"\nExecuting POST /configure to mint '{product_alias}' and {len(sql_plans)} Nested Plans...")
    try:
        r = requests.post(cfg_url, headers=headers, json=payload, timeout=30)
        print(f"HTTP Return Code: {r.status_code}")
        if r.status_code in [200, 201, 202]:
            print(f"Successfully generated Draft configuration for {product_alias}!")
            print(json.dumps(r.json(), indent=2))
        else:
            print("Submission FAILED:")
            try:
                print(json.dumps(r.json(), indent=2))
            except:
                print(r.text)
    except Exception as e:
        print(f"Socket or HTTP connection error: {e}")

if __name__ == "__main__":
    main()
