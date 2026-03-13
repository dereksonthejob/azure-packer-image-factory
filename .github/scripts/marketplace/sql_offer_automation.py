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
        "sql-server-2025-gen2": {
            "name": "SQL Server 2025",
            "plans": [
                {
                    "id": "plan-sql2025-ws2025-dev",
                    "img_def": "imgdef-sql2025-ws2025-dev-gen2",
                    "title": "SQL Server 2025 Developer on Windows Server 2025 (Gen2)",
                    "summary": "Microsoft SQL Server 2025 Developer Edition optimized on Windows Server 2025. Perfect for dev/test environments.",
                    "description": "<p>Deploy the ultimate, fully-featured SQL Server 2025 Developer Edition on the highly secure Windows Server 2025 foundation. This Gen2 Trusted Launch deployment is optimized specifically for non-production development and testing workflows, offering full Enterprise-level capabilities at zero licensing cost (standard Azure compute rates apply). Includes advanced vector search paradigms, secure enclaves, and intelligent query processing seamlessly integrated into the newest Windows Server architecture.</p>"
                },
                {
                    "id": "plan-sql2025-ws2025-std",
                    "img_def": "imgdef-sql2025-ws2025-std-gen2",
                    "title": "SQL Server 2025 Standard on Windows Server 2025 (Gen2)",
                    "summary": "Microsoft SQL Server 2025 Standard on Windows Server 2025. Production-ready relational performance.",
                    "description": "<p>Power your tier-1 production applications with Microsoft SQL Server 2025 Standard natively integrated upon Windows Server 2025. Engineered with Gen2 Trusted Launch security, this image offers highly scalable data performance, seamless hybrid cloud capability, industry-leading data integration, and advanced JSON/Vector capabilities. Highly optimized for medium-scale enterprise infrastructures requiring high-availability deployment structures.</p>"
                },
                {
                    "id": "plan-sql2025-ws2025-ent",
                    "img_def": "imgdef-sql2025-ws2025-ent-gen2",
                    "title": "SQL Server 2025 Enterprise on Windows Server 2025 (Gen2)",
                    "summary": "Microsoft SQL Server 2025 Enterprise on Windows Server 2025. Ultimate data warehouse and analytics ecosystem.",
                    "description": "<p>Execute mission-critical, large-scale database operations using Microsoft SQL Server 2025 Enterprise Edition on Windows Server 2025.</p><h2>Enterprise SQL Best Practices Built-In</h2><ul><li><strong>Azure Update Manager Compatible:</strong> Fully supports native SQL IaaS extension patching pipelines.</li><li><strong>Time-Saving Updates:</strong> Ships with the absolute latest Windows and SQL cumulative updates pre-installed via our automated Packer factory, saving days of enterprise patching cycles.</li><li><strong>Storage Optimization & TempDB Separation:</strong> Architected for strict Data/OS disk separation parameters, natively supporting TempDB routing to the ephemeral high-performance D: drive during Azure ARM template deployment.</li></ul>"
                }
            ]
        },
        "8a9b1fd3-aef8-44dc-a088-14d4ae49417a": {   # Product ID for SQL Server 2022 natively found by user
            "name": "SQL Server 2022 on Windows Server 2022",
            "plans": [
                {
                    "id": "1be753ec-23bc-4ed3-ada3-96cb342fef8e",
                    "img_def": "imgdef-sql2022-ws2022-gen2",   # Mapped to Base image
                    "title": "SQL Server 2022 on Windows Server 2022 (Hardened Pipeline)",
                    "summary": "Meticulously automated Windows Server 2022 Gen2 operating system hardened via CI/CD pipelines.",
                    "description": "<h2>Packer-Validated Secure Execution</h2><p>This image is directly engineered by <strong>Derek Coleman & Associates Corp.</strong> using autonomous Azure Packer Image Factory protocols. Unlike generic Publisher templates, this image guarantees absolute footprint transparency, explicitly mitigating End-Of-Life binaries (such as .NET 6.0 vulnerabilities) prior to Sysprep execution. This creates a secure, perfectly pristine Gen2 foundation supporting extreme Azure compliance thresholds.</p>"
                },
                {
                    "id": "309cf02e-acc4-4103-9a3b-812ae15acfcd",
                    "img_def": "imgdef-sql2022-ws2022-developer-gen2",
                    "title": "SQL Server 2022 Developer on Windows Server 2022 (CI/CD Validated)",
                    "summary": "SQL Server 2022 Developer edition hardened specifically via rigorous Azure DevOps CI/CD Factory validation.",
                    "description": "<h2>Zero-Trust Developer Environments</h2><p>Seamlessly deploy a seamlessly patched SQL Server 2022 Developer environment on Windows Server 2022. This Gen2 Virtual Machine utilizes automated Packer build pipelines to guarantee malicious code footprint reduction and explicit Windows Defender integration loops prior to artifact publication. Intentionally engineered to exceed standard Microsoft image compliance checks.</p>"
                },
                {
                    "id": "e2d677dd-1135-4ed4-9e32-a5e2978000bc",
                    "img_def": "imgdef-sql2022-ws2022-standard-gen2",
                    "title": "SQL Server 2022 Standard on Windows Server 2022 (CI/CD Validated)",
                    "summary": "SQL Server 2022 Standard meticulously built through advanced pipeline orchestration for resilient production security.",
                    "description": "<h2>Resilient Automated Delivery (RAD)</h2><p>This SQL Server 2022 Standard deployment is uniquely constructed via automated HashiCorp Packer integration mechanisms. By bypassing manual configuration, this artifact is mathematically consistent and perfectly patched against severe CVSS topologies (including implicit .NET runtime depreciation factors) out-of-the-box.</p><h2>Enterprise SQL Architecture Advantages</h2><ul><li><strong>Azure Update Manager Integration:</strong> Fully compliant with Azure's first-party continuous update matrices.</li><li><strong>Pre-Installed Updates (Save Days):</strong> We drastically reduce deployment friction by slipstreaming the newest cumulative SQL updates natively into the baseline image.</li><li><strong>Disk Segregation & TempDB:</strong> Optimally configured for OS/Data disk separation, directly enabling TempDB initialization on your high-speed temporary drive (D:) upon deployment.</li></ul>"
                },
                {
                    "id": "63ee76ac-3f62-45f3-afe3-87f1e923fd2d",
                    "img_def": "imgdef-sql2022-ws2022-enterprise-gen2",
                    "title": "SQL Server 2022 Enterprise on Windows Server 2022 (CI/CD Validated)",
                    "summary": "SQL Server 2022 Enterprise executing on radically hardened Azure pipelines with proactive Defender scanning.",
                    "description": "<h2>Unmatched Enterprise Governance</h2><p>Our SQL Server 2022 Enterprise iteration delivers maximum transaction efficiency securely paired against an aggressive <strong>Packer CI/CD Security Matrix</strong>.</p><h2>Why this image outperforms Standard builds:</h2><ul><li><strong>Azure Update Manager Compatibility:</strong> Full integration with explicit SQL VM Update orchestration.</li><li><strong>Critical Time Savings:</strong> Saves enterprise DBA teams literal days by shipping with the highest tier of pre-installed SQL and OS cumulative updates directly baked into the VHD.</li><li><strong>SQL Best Practices - Data & TempDB Separation:</strong> Explicitly engineered to route TempDB to distinct disks and support total OS/Data segregation topologies for extreme IOPS environments.</li></ul>"
                }
            ]
        }
    }
    
    resources = []
    
    for product_id, product_data in sql_products.items():
        print(f"Synthesizing Configuration Payload for {product_data['name']} ({product_id})...")
        
        # 1. Product (Offer) Creation Shell
        resources.append({
            "$schema": "https://schema.mp.microsoft.com/schema/product/2022-03-01-preview3",
            "id": f"product/{product_id}",
            "name": product_data['name'],
            "kind": "azureVM"
        })
        
        # 2. Plan Minting Loop
        for plan_obj in product_data['plans']:
            p_id = plan_obj['id']
            p_title = plan_obj['title']
            p_summary = plan_obj['summary']
            p_desc = plan_obj['description']
            img_def = plan_obj['img_def']
            
            # Core Plan structural node
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/plan/2022-03-01-preview2",
                "id": f"plan/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "name": p_title
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
            
            # Hardware & Image Technical Configuration
            resources.append({
                "$schema": "https://schema.mp.microsoft.com/schema/virtual-machine-plan-technical-configuration/2022-03-01-preview2",
                "id": f"virtual-machine-plan-technical-configuration/{product_id}/{p_id}",
                "product": f"product/{product_id}",
                "plan": f"plan/{product_id}/{p_id}",
                "operatingSystemFamily": "Windows",
                "operatingSystem": "Windows", 
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
                    "Standard_D8s_v5",
                    "Standard_D16s_v5",
                    "Standard_E8s_v5",
                    "Standard_E16s_v5",
                    "Standard_M8ms",
                    "Standard_M16ms"
                ],
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
    
    print(f"\nExecuting POST /configure to mint ALL SQL Server Topologies and Nested Plans...")
    try:
        r = requests.post(cfg_url, headers=headers, json=payload, timeout=30)
        print(f"HTTP Return Code: {r.status_code}")
        if r.status_code in [200, 201, 202]:
            print(f"Successfully generated Marketing and Technical configurations for ALL SQL Server Offers!")
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
