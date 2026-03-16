@description('Name of the AI Hub resource')
param hubName string = 'ai-hub-${uniqueString(resourceGroup().id)}'

@description('Name of the AI Project resource')
param projectName string = 'ai-project-agentic-${uniqueString(resourceGroup().id)}'

@description('The location for all resources')
param location string = resourceGroup().location

@description('Azure OpenAI Service Name')
param openAiName string = 'oai-agentic-${uniqueString(resourceGroup().id)}'

var storageAccountName = 'stai${uniqueString(resourceGroup().id)}'
var keyVaultName = 'kv-ai-${uniqueString(resourceGroup().id)}'
var appInsightsName = 'appi-ai-${uniqueString(resourceGroup().id)}'

// Storage Account for Hub
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    defaultToOAuthAuthentication: true
  }
}

// Key Vault for Hub
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
  }
}

// Application Insights for Hub
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// Azure AI Hub
resource aiHub 'Microsoft.MachineLearningServices/workspaces@2024-04-01-preview' = {
  name: hubName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  kind: 'Hub'
  properties: {
    friendlyName: 'AI Foundry Hub'
    description: 'Central Hub for Azure AI projects'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: applicationInsights.id
  }
}

// Azure AI Project (Isolated workspace for Agents)
resource aiProject 'Microsoft.MachineLearningServices/workspaces@2024-04-01-preview' = {
  name: projectName
  location: location
  kind: 'Project'
  properties: {
    friendlyName: 'Self-Healing CI/CD Agent Project'
    hubResourceId: aiHub.id
  }
}

// Azure OpenAI Service
resource openAiService 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAiName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: openAiName
  }
}

// GPT-4o Model Deployment
resource codexDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openAiService
  name: 'gpt-4o'
  sku: {
    name: 'Standard'
    capacity: 30
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-05-13'
    }
  }
}

// ML Compute Instance (Execution environment for the agent — Always-On)
resource agentCompute 'Microsoft.MachineLearningServices/workspaces/computes@2024-04-01-preview' = {
  parent: aiProject
  name: 'agent-codex-ci-01'
  location: location
  identity: {
    type: 'SystemAssigned'  // Managed Identity for Key Vault secret access
  }
  properties: {
    computeType: 'ComputeInstance'
    disableLocalAuth: true
    properties: {
      vmSize: 'Standard_D4s_v3'  // 4 vCPU, 16GB — required for Puppeteer + multi-agent
      idleTimeBeforeShutdown: 'PT0S'  // Always-on — never auto-shutdown
    }
  }
}

// KV = Key Vault resource alias (reference only, not created here — assumed pre-existing)
resource existingKeyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

// Grant Compute Instance Managed Identity the Key Vault Secrets User role
resource kvSecretUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingKeyVault.id, agentCompute.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: existingKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: agentCompute.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output aiProjectName string = aiProject.name
output computeInstanceName string = agentCompute.name
output codexEndpoint string = openAiService.properties.endpoint
output agentComputePrincipalId string = agentCompute.identity.principalId
