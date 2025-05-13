@description('Base name of the function app that will be used to generate unique resource names')
param baseName string

@description('Location for all resources.')
param location string = resourceGroup().location

@description('The SKU of the App Service Plan')
@allowed([
  'Y1'  // Consumption plan
  'B1'  // Basic
  'S1'  // Standard
  'P1V2' // Premium V2
])
param appServicePlanSku string = 'Y1'

@description('Runtime version')
param runtimeVersion string = '3.11'

@description('Value for AZCF_ENV_SOMEVALUE environment variable')
param azcf_env_somevalue string

// Generate unique names for resources
var functionAppName = '${baseName}-func'
var appServicePlanName = '${baseName}-plan'
// Step 1: Lowercase and remove hyphens from the resource group name
var rgNameClean = replace(toLower(resourceGroup().name), '-', '')
// Step 2: Lowercase and remove hyphens from the baseName
var baseNameClean = replace(toLower(baseName), '-', '')
// Step 3: Concatenate cleaned resource group name, cleaned baseName, and 'sa' suffix
var storageAccountNameRaw = '${rgNameClean}${baseNameClean}sa'
// Step 4: Ensure the name is at least 3 characters, then take the first 24 characters to comply with Azure Storage naming rules
var storageAccountName = take(length(storageAccountNameRaw) < 3 ? '${storageAccountNameRaw}stor' : storageAccountNameRaw, 24)
var appInsightsName = '${baseName}-insights'

// Storage Account for Function App
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// App Service Plan (Hosting Plan)
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSku
  }
  // Simplified properties - same for all plan types
  properties: {
    reserved: true // Required for Linux
  }
}

// Application Insights for monitoring
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Function App
resource functionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|${runtimeVersion}'
      appSettings: [
        // Function runtime settings
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'  // Hardcoded to Python
        }
        // Python version setting
        {
          name: 'PYTHON_VERSION'
          value: runtimeVersion
        }
        // Application Insights settings
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AZCF_ENV_SOMEVALUE'
          value: azcf_env_somevalue
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

// Output the function app URL
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output functionAppName string = functionApp.name
output storageAccountName string = storageAccountName
