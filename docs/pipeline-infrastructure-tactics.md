# Pipeline Infrastructure Tactics

This document codifies critical scaling and execution workarounds required for the Azure Marketplace Image Factory.

## Custom Self-Hosted Runners (VMSS)

The image build matrices require significant concurrency to mint Ubuntu and Windows Topologies simultaneously without hitting generic GitHub scale limits. We employ native Azure Virtual Machine Scale Sets (VMSS) for these runners.

### Rootless Daemon Bootstrapping (PEP 668)
Because the VMSS runners use raw, lean Ubuntu images (not customized `actions/runner-images`), standard daemon endpoints like `az cli` are not pre-installed. 

* **The Problem:** The `azure/login@v2` action attempts to install the CLI directly leveraging root `pip`. Under Python PEP 668 (introduced heavily in Ubuntu 24.04+), this triggers an `externally-managed-environment` hard fault, immediately terminating the action.
* **The Fix:** Workflows must execute an explicit curl bootstrap to pull the `.deb` directly:
  ```bash
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  ```

### OIDC Service Principal Credentials
The GitHub Action `azure/login@v2` exhibits erratic behavior when passing the raw `AZURE_CREDENTIALS` JSON string payload directly into the VMSS runner execution context. 

* **The Problem:** The payload mapping fails to inject the variables into the shell environment seamlessly via string block.
* **The Fix:** Explicitly unpack the `secrets.*` keys natively via a JSON struct using the single-quote enclosure:
  ```yaml
  with:
    creds: '{"clientId":"${{ secrets.AZURE_CLIENT_ID }}","clientSecret":"${{ secrets.AZURE_CLIENT_SECRET }}","subscriptionId":"${{ secrets.AZURE_SUBSCRIPTION_ID }}","tenantId":"${{ secrets.AZURE_TENANT_ID }}"}'
  ```

*Failure to observe either of these patterns will result in instant pipeline failure during the Setup & Authentication phase across all topologies.*
