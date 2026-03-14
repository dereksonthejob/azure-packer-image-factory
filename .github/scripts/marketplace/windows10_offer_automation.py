import requests
import msal
import json
import time
import os

def run_windows10_automation():
    print("Initiating Windows 10 First-Party Desktop Canonical SEO Plan Ingestion...")
    
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
    
    windows10_products = {
        "windows-10-desktop": {
            "name": "Windows 10 Desktop (Hardened)",
            "logo_path": ".agents/workflows/windows-logo.png",
            "plans": [
                {
                    "id": "win10-22h2-ms",
                    "img_def": "imgdef-win10-22h2-ent-multisession-gen2",
                    "title": "Windows 10 Enterprise Multi-Session (22H2)",
                    "summary": "Hardened Windows 10 Enterprise Multi-Session (22H2) optimized for AVD workloads.",
                    "description": "<p>Deploy a highly performant, globally compliant multi-session virtual desktop environment utilizing the final stable 22H2 branch.</p>"
                },
                {
                    "id": "win10-22h2-ent",
                    "img_def": "imgdef-win10-22h2-ent-gen2",
                    "title": "Windows 10 Enterprise (22H2)",
                    "summary": "Single-user canonical Windows 10 Enterprise (22H2) with rigorous CVE mitigation applied.",
                    "description": "<p>Provide dedicated knowledge workers with a heavily shielded Windows 10 Enterprise workstation.</p>"
                },
                {
                    "id": "win10-22h2-pro",
                    "img_def": "imgdef-win10-22h2-pro-gen2",
                    "title": "Windows 10 Professional (22H2)",
                    "summary": "Administrative Windows 10 Professional (22H2) single-user compute instance.",
                    "description": "<p>Cost-effective Windows 10 Professional deployment fully secured against End-of-Life .NET frameworks.</p>"
                },
                {
                    "id": "win10-21h2-ms",
                    "img_def": "imgdef-win10-21h2-ent-multisession-gen2",
                    "title": "Windows 10 Enterprise Multi-Session (21H2)",
                    "summary": "Long-Term Servicing equivalent Windows 10 Multi-Session (21H2) for targeted compliance.",
                    "description": "<p>Lock into the stable 21H2 pipeline for highly-regulated application isolation within Azure Virtual Desktop.</p>"
                },
                {
                    "id": "win10-21h2-ent",
                    "img_def": "imgdef-win10-21h2-ent-gen2",
                    "title": "Windows 10 Enterprise (21H2)",
                    "summary": "Stable branch legacy Windows 10 Enterprise (21H2) workstation definition.",
                    "description": "<p>Ensure structural operational backward compatibility with aging corporate software payloads atop Windows 10 Enterprise 21H2.</p>"
                }
            ]
        }
    }
    
    resources = []
    
    for product_id, product_data in windows10_products.items():
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
    
    print("\nExecuting POST /configure to mint ALL Windows 10 Topologies and Nested Plans...")
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
    run_windows10_automation()
