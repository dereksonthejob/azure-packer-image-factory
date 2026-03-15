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
        print("Failed to acquire MS Graph Token")
        sys.exit(1)

    token = result["access_token"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    
    sql_products = {
        "8a9b1fd3-aef8-44dc-a088-14d4ae49417a": {   # Canonical SQL Server Product ID
            "name": "SQL Server Portfolio (2019 & 2022)",
            "external_id": "sql-server-portfolio-gen2",
            "plans": [
                # SQL Server 2022 on Windows Server 2022
                {
                    "id": "sql2022-dev-ws2022",
                    "img_def": "imgdef-sql2022-ws2022-developer-gen2",
                    "title": "SQL Server 2022 Developer on Windows Server 2022",
                    "summary": "SQL Server 2022 Developer edition hardened via rigorous CI/CD Pipeline validation.",
                    "description": "<p>Zero-Trust non-production execution with canonical SQL updates natively injected into Windows Server 2022.</p>",
                    "sku_id": "sql2022-dev-ws2022"
                },
                {
                    "id": "sql2022-std-ws2022",
                    "img_def": "imgdef-sql2022-ws2022-standard-gen2",
                    "title": "SQL Server 2022 Standard on Windows Server 2022",
                    "summary": "SQL Server 2022 Standard meticulously built through advanced pipeline orchestration.",
                    "description": "<p>Resilient continuous execution leveraging automated TempDB provisioning and pre-installed CUs.</p>",
                    "sku_id": "sql2022-std-ws2022"
                },
                {
                    "id": "sql2022-ent-ws2022",
                    "img_def": "imgdef-sql2022-ws2022-enterprise-gen2",
                    "title": "SQL Server 2022 Enterprise on Windows Server 2022",
                    "summary": "SQL Server 2022 Enterprise executing on radically hardened Azure pipelines.",
                    "description": "<p>Mission-critical 2022 Enterprise execution optimizing extreme IOPS via distinct OS/Data segregation topologies.</p>",
                    "sku_id": "sql2022-ent-ws2022"
                },
                
                # SQL Server 2022 on Windows Server 2019
                {
                    "id": "sql2022-dev-ws2019",
                    "img_def": "imgdef-sql2022-ws2019-developer-gen2",
                    "title": "SQL Server 2022 Developer on Windows Server 2019",
                    "summary": "SQL Server 2022 Developer edition for legacy WS 2019 compliance needs.",
                    "description": "<p>Non-production WS 2019 testing matrix integrated with the newest SQL 2022 database engines.</p>",
                    "sku_id": "sql2022-dev-ws2019"
                },
                {
                    "id": "sql2022-std-ws2019",
                    "img_def": "imgdef-sql2022-ws2019-standard-gen2",
                    "title": "SQL Server 2022 Standard on Windows Server 2019",
                    "summary": "SQL Server 2022 Standard strictly conforming to Windows Server 2019 policy.",
                    "description": "<p>Stable production tier SQL 2022 executing atop the proven Windows Server 2019 foundation.</p>",
                    "sku_id": "sql2022-std-ws2019"
                },
                {
                    "id": "sql2022-ent-ws2019",
                    "img_def": "imgdef-sql2022-ws2019-enterprise-gen2",
                    "title": "SQL Server 2022 Enterprise on Windows Server 2019",
                    "summary": "SQL Server 2022 Enterprise executing on legacy WS 2019 enterprise clusters.",
                    "description": "<p>Unmatched database scalability operating in high-demand enterprise matrices constrained to Server 2019 layers.</p>",
                    "sku_id": "sql2022-ent-ws2019"
                },

                # SQL Server 2019 on Windows Server 2022
                {
                    "id": "sql2019-dev-ws2022",
                    "img_def": "imgdef-sql2019-ws2022-developer-gen2",
                    "title": "SQL Server 2019 Developer on Windows Server 2022",
                    "summary": "Legacy SQL Server 2019 engines executing on the highly modern Windows Server 2022 core.",
                    "description": "<p>Test legacy 2019 database workloads efficiently against highly secure Server 2022 kernels.</p>",
                    "sku_id": "sql2019-dev-ws2022"
                },
                {
                    "id": "sql2019-std-ws2022",
                    "img_def": "imgdef-sql2019-ws2022-standard-gen2",
                    "title": "SQL Server 2019 Standard on Windows Server 2022",
                    "summary": "SQL 2019 Standard deployed aggressively atop Windows Server 2022 hypervisors.",
                    "description": "<p>Combine universally trusted SQL 2019 execution with hyper-modern Gen2 secure launch protocols.</p>",
                    "sku_id": "sql2019-std-ws2022"
                },
                {
                    "id": "sql2019-ent-ws2022",
                    "img_def": "imgdef-sql2019-ws2022-enterprise-gen2",
                    "title": "SQL Server 2019 Enterprise on Windows Server 2022",
                    "summary": "Mission-Critical SQL 2019 Enterprise bounded strictly to Server 2022 infrastructures.",
                    "description": "<p>Support immense historical data lakes via SQL 2019 backed natively by Windows Server 2022 network stacks.</p>",
                    "sku_id": "sql2019-ent-ws2022"
                },

                # SQL Server 2019 on Windows Server 2019
                {
                    "id": "sql2019-dev-ws2019",
                    "img_def": "imgdef-sql2019-ws2019-developer-gen2",
                    "title": "SQL Server 2019 Developer on Windows Server 2019",
                    "summary": "Native SQL Server 2019 Developer on Server 2019 infrastructure.",
                    "description": "<p>Maximum backward-compatibility testing paradigm for legacy hybrid deployments.</p>",
                    "sku_id": "sql2019-dev-ws2019"
                },
                {
                    "id": "sql2019-std-ws2019",
                    "img_def": "imgdef-sql2019-ws2019-standard-gen2",
                    "title": "SQL Server 2019 Standard on Windows Server 2019",
                    "summary": "Native SQL Server 2019 Standard on proven Server 2019 architectures.",
                    "description": "<p>Highly isolated, explicitly predictable relational processing on identically aligned Server versions.</p>",
                    "sku_id": "sql2019-std-ws2019"
                },
                {
                    "id": "sql2019-ent-ws2019",
                    "img_def": "imgdef-sql2019-ws2019-enterprise-gen2",
                    "title": "SQL Server 2019 Enterprise on Windows Server 2019",
                    "summary": "Native SQL Server 2019 Enterprise executing atop Server 2019 environments.",
                    "description": "<p>The canonical 2019 legacy matrix optimized strictly for mission-critical older Azure topologies.</p>",
                    "sku_id": "sql2019-ent-ws2019"
                }
            ]
        }
    }
    
    for product_id, product_data in sql_products.items():
        resources = []
        print(f"Synthesizing Configuration Payload for {product_data['name']} ({product_id})...")
        
        # 1. Product (Offer) Creation Shell
        # (Omitted to prevent immutable externalId conflict errors)
        
        # 1.5 Offer-Level Listing (Required Support & CSP Contacts)
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/listing/2022-03-01-preview3",
            "id": f"listing/{product_id}/public/main/default/en-us",
            "product": f"product/{product_id}",
            "kind": "azureVM",
            "languageId": "en-us",
            "title": product_data['name'],
            "description": f"<p>Deploy {product_data['name']} natively integrated with Azure Update Manager for Enterprise Scale workflows.</p>",
            "searchResultSummary": f"High-performance {product_data['name']} offering.",
            "shortDescription": f"Enterprise optimized {product_data['name']} environments.",
            "privacyPolicyLink": "https://www.dcassociatesgroup.com/privacy",
            "globalSupportWebsite": "https://www.dcassociatesgroup.com",
            "cloudSolutionProviderMarketingMaterials": "https://www.dcassociatesgroup.com",
            "supportContact": {
                "name": "Support Team",
                "email": "support@dcassociatesgroup.com",
                "phone": "18564484318"
            },
            "engineeringContact": {
                "name": "Engineering Team",
                "email": "support@dcassociatesgroup.com",
                "phone": "18564484318"
            },
            "cloudSolutionProviderContact": {
                "name": "CSP Team",
                "email": "support@dcassociatesgroup.com",
                "phone": "18564484318"
            }
        })

        # 1.6 Preview Audience Configurations (Offer-Level)
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

        
        # 2. Plan Minting Loop
        for plan_obj in product_data['plans']:
            p_id = plan_obj['id']
            p_title = plan_obj['title']
            p_summary = plan_obj['summary']
            p_desc = plan_obj['description']
            img_def = plan_obj['img_def']
            
            # Core Plan structural node (Setting Azure Global & Government explicit regions)
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/plan/2022-03-01-preview2",
                "id": f"plan/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "identity": {"externalId": p_id},
                "alias": p_title,
                "azureRegions": ["azureGlobal"]
            })

            # EXACT Plan Listing SEO configuration mapping directly to Memory store
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
            
            # Plan Pricing Availability Strategies (Overrides for Legacy Graph Restrictions)
            if "developer" in p_title.lower():
                pricing_structure = {
                    "licenseModel": "payAsYouGo",
                    "corePricing": {
                        "priceInputOption": "free"
                    }
                }
            else:
                pricing_structure = {
                    "licenseModel": "payAsYouGo",
                    "corePricing": {
                        "priceInputOption": "perCore",
                        "pricePerCore": 0.09
                    }
                }

            # Plan Pricing payload mapping
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/price-and-availability-plan/2022-03-01-preview3",
                "id": f"price-and-availability-plan/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "plan": f"plan/{product_id}/{p_id}",
                "pricing": pricing_structure,
                "visibility": "visible",
                "audience": "public",
                "customerMarkets": "allMarkets"
            })
            
            # Hardware & Image Technical Configuration
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/virtual-machine-plan-technical-configuration/2022-03-01-preview6",
                "id": f"virtual-machine-plan-technical-configuration/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "plan": f"plan/{product_id}/{p_id}",
                "skus": [
                    {
                        "imageType": "x64Gen2",
                        "skuId": plan_obj['sku_id'],
                        "securityType": ["trusted"]
                    }
                ],
                "operatingSystem": {
                    "family": "windows",
                    "type": "windowsServer2022"
                },
                "recommendedVmSizes": [
                    "d8s-standard-v5",
                    "d16s-standard-v5",
                    "e8s-standard-v5",
                    "e16s-standard-v5",
                    "e32s-standard-v5"
                ],
                "vmProperties": {
                    "supportsAcceleratedNetworking": True,
                    "supportsCloudInit": False,
                    "supportsExtensions": True,
                    "supportsBackup": True,
                    "supportsAadLogin": True,
                    "networkVirtualAppliance": False
                },
                "vmImageVersions": [] if os.environ.get("REMOVE_IMAGES") == "true" else [
                    {
                        "versionNumber": get_latest_gallery_version(img_def),
                        "vmImages": [
                            {
                                "imageType": "x64Gen2",
                                "source": {
                                    "sourceType": "sharedImageGallery",
                                    "sharedImage": {
                                        "tenantId": tenant_id,
                                        "resourceId": f"/subscriptions/f4085274-4e9d-4e93-8360-67a4be900d81/resourceGroups/RG-PACKER-IMAGE-FACTORY-EASTUS/providers/Microsoft.Compute/galleries/acgpackerfactoryeastus/images/{img_def}/versions/{get_latest_gallery_version(img_def)}"
                                    }
                                }
                            }
                        ]
                    }
                ]
            })
            
        payload = {
            "$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
            "resources": resources
        }
        
        cfg_url = "https://graph.microsoft.com/rp/product-ingestion/configure?api-version=2022-03-01-preview2"
        
        print(f"\nExecuting POST /configure to mint {product_data['name']}...")
        try:
            r = requests.post(cfg_url, headers=headers, json=payload, timeout=30)
            print(f"HTTP Return Code: {r.status_code}")
            if r.status_code in [200, 201, 202]:
                print(f"Successfully generated Marketing and Technical configurations for {product_data['name']}!")
            else:
                print(f"Error submitting {product_data['name']}:")
            print(json.dumps(r.json(), indent=2))
        except Exception as e:
            print(f"Socket or HTTP connection error: {e}")

if __name__ == "__main__":
    main()
