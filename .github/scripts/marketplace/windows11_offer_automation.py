import requests
import msal
import json
import time
import os

def run_windows11_automation():
    print("Initiating Windows 11 First-Party Desktop Canonical SEO Plan Ingestion...")
    
    client_id = os.environ.get("AZURE_CLIENT_ID")
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")

    if not client_id or not tenant_id or not client_secret:
        print("Missing required API authentication variables.")
        return

    authority = "https://login.microsoftonline.com/" + tenant_id
    def get_latest_gallery_version(img_def_target):
        mgmt_app = msal.ConfidentialClientApplication(client_id, authority=authority, client_credential=client_secret)
        mgmt_result = mgmt_app.acquire_token_for_client(scopes=["https://management.azure.com/.default"])
        if "access_token" not in mgmt_result:
            return "1.0.0"
            
        mgmt_headers = {"Authorization": f"Bearer {mgmt_result['access_token']}"}
        sub_id = "f4085274-4e9d-4e93-8360-67a4be900d81"
        rg = "RG-PACKER-IMAGE-FACTORY-EASTUS"
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
        print("Authentication to Microsoft Graph Failed.")
        return

    token = result["access_token"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    
    windows11_products = {
        "windows-11-desktop": {
            "name": "Windows 11 Desktop (Hardened)",
            "logo_path": ".agents/workflows/windows-logo.png",
            "plans": [
                {
                    "id": "win11-23h2-ms",
                    "img_def": "imgdef-win11-23h2-ent-multisession-gen2",
                    "title": "Windows 11 Enterprise Multi-Session (23H2)",
                    "summary": "Hardened Windows 11 Enterprise Multi-Session (23H2) specifically engineered for Azure Virtual Desktop.",
                    "description": "<p>Deploy the flagship multi-user orchestration environment from Microsoft. Verified and fully secured utilizing Canonical 23H2 constructs.</p>"
                },
                {
                    "id": "win11-23h2-ent",
                    "img_def": "imgdef-win11-23h2-ent-gen2",
                    "title": "Windows 11 Enterprise (23H2)",
                    "summary": "Canonical Windows 11 Enterprise (23H2) for dedicated, highly compliant engineering workloads.",
                    "description": "<p>Provide top-tier executive and developer workstations strictly adhering to Enterprise licensing bounds.</p>"
                },
                {
                    "id": "win11-23h2-pro",
                    "img_def": "imgdef-win11-23h2-pro-gen2",
                    "title": "Windows 11 Professional (23H2)",
                    "summary": "Cost-optimized single-user Windows 11 Professional desktop environment.",
                    "description": "<p>Ideal for administrative general-purpose architecture without strict Enterprise policy requirements.</p>"
                },
                {
                    "id": "win11-22h2-ms",
                    "img_def": "imgdef-win11-22h2-ent-multisession-gen2",
                    "title": "Windows 11 Enterprise Multi-Session (22H2)",
                    "summary": "Mature branch Windows 11 Enterprise Multi-Session (22H2) for specialized UI backwards compatibility.",
                    "description": "<p>Lock into the reliable 22H2 Multi-Session feature gate for tested compliance workloads inside AVD.</p>"
                },
                {
                    "id": "win11-22h2-ent",
                    "img_def": "imgdef-win11-22h2-ent-gen2",
                    "title": "Windows 11 Enterprise (22H2)",
                    "summary": "Stable branch legacy Windows 11 Enterprise setup for previous-generation compute parity.",
                    "description": "<p>Leverage heavily tested Microsoft 22H2 architectures natively scrubbed of zero-day vulnerabilities.</p>"
                }
            ]
        }
    }
    
    resources = []
    
    for product_id, product_data in windows11_products.items():
        print(f"Synthesizing Configuration Payload for {product_data['name']} ({product_id})...")
        
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/product/2022-03-01-preview3",
            "id": f"product/{product_id}",
            "name": product_data['name'],
            "kind": "azureVM"
        })
        
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/price-and-availability-offer/2022-03-01-preview3",
            "id": f"price-and-availability-offer/{product_id}",
            "product": f"product/{product_id}",
            "previewAudiences": [
                {
                    "type": "subscription",
                    "id": "48fe169a-1451-4f57-8487-96a81f41e539",
                    "label": "Testers"
                }
            ]
        })

        for plan_obj in product_data['plans']:
            p_id = plan_obj['id']
            p_title = plan_obj['title']
            p_summary = plan_obj['summary']
            p_desc = plan_obj['description']
            img_def = plan_obj.get("img_def")
            
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/plan/2022-03-01-preview2",
                "id": f"plan/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "name": p_title
            })
            
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/plan-listing/2022-03-01-preview3",
                "id": f"plan-listing/{product_id}/public/main/{p_id}/en-us",
                "product": f"product/{product_id}",
                "plan": f"plan/{product_id}/{p_id}",
                "kind": "azureVM-plan",
                "languageId": "en-us",
                "name": p_title,
                "summary": p_summary,
                "description": p_desc
            })

            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/price-and-availability-plan/2022-03-01-preview3",
                "id": f"price-and-availability-plan/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "plan": f"plan/{product_id}/{p_id}",
                "pricing": {
                    "licenseModel": "payAsYouGo",
                    "corePricing": {
                        "priceInputOption": "perCore",
                        "pricePerCore": 0.09
                    }
                },
                "visibility": "visible",
                "audience": "public",
                "customerMarkets": "allMarkets"
            })
            
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/virtual-machine-plan-technical-configuration/2022-03-01-preview2",
                "id": f"virtual-machine-plan-technical-configuration/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "plan": f"plan/{product_id}/{p_id}",
                "operatingSystemFamily": "Windows",
                "operatingSystem": "windows",
                "generation": "gen2",
                "state": "generalized",
                "securityType": "TrustedLaunch",
                "supportsAcceleratedNetworking": True,
                "supportsCloudInitConfiguration": False,
                "supportsVmExtensions": True,
                "supportsBackup": True,
                "supportsMicrosoftEntraIdentityAuthentication": True,
                "isNetworkVirtualAppliance": False,
                "recommendedSizes": [
                    "Standard_D2s_v5",
                    "Standard_D4s_v5",
                    "Standard_D8s_v5",
                    "Standard_E2s_v5",
                    "Standard_E4s_v5",
                    "Standard_E8s_v5"
                ],
                "osType": "windows",
                "azureRegions": [
                    "azureGlobal"
                ],
                "cloudInstanceCapabilities": [],
                "azureComputeGalleryImageIdentities": [
                    {
                        "subscriptionId": "f4085274-4e9d-4e93-8360-67a4be900d81",  
                        "resourceGroup": "RG-PACKER-IMAGE-FACTORY-EASTUS",
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
    
    print("\nExecuting POST /configure to mint ALL Windows 11 Topologies and Nested Plans...")
    try:
        r = requests.post(cfg_url, headers=headers, json=payload, timeout=30)
        print(f"HTTP Return Code: {r.status_code}")
        
        if r.status_code in [200, 202]:
            job_id = r.json().get("jobId")
            print(f"Polling Job ID: {job_id}")
            for _ in range(12):
                time.sleep(5)
                stat_url = f"https://graph.microsoft.com/rp/product-ingestion/configure/{job_id}/status?api-version=2022-03-01-preview2"
                stat = requests.get(stat_url, headers=headers, timeout=10).json()
                s = stat.get("jobStatus", "").lower()
                print(f"Current Execution Status: {s}")
                if s in ["completed", "succeeded"]: 
                    print("--> Matrix Injection Succeeded!")
                    break
                if s == "failed":
                    print("--> MAPPING FAILED. DIAGNOSTICS:")
                    print(json.dumps(stat, indent=2))
                    break
        else:
            print("API Rejection:", r.text)
            
    except Exception as e:
        print("Network Socket Timeout or Execution Error:", str(e))

if __name__ == "__main__":
    run_windows11_automation()
