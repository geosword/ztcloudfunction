#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration Variables (expected to be set in your environment) ---
# AZCF_RG: Resource Group Name (e.g., ztech)
# AZCF_NAME: Base name for resources, also used as the function code folder name (e.g., ztfunction)
# AZCF_LOCATION: Azure region (e.g., uksouth)
# AZCF_ENV_SOMEVALUE: Value for the AZCF_ENV_SOMEVALUE app setting (e.g., "ZipTech")

# --- Script Configuration ---
BICEP_FILE_PATH="./infra/function.bicep" # Path to your Bicep file

# --- Derived Variables (based on your environment variables and Bicep logic) ---
# The Bicep template defines 'var functionAppName = "${baseName}-func"'
# So, the actual Azure Function App resource name will be ${AZCF_NAME}-func
FUNCTION_APP_RESOURCE_NAME="${AZCF_NAME}-func"

# Path to the folder containing your Python function code
# Assumes the folder is named after $AZCF_NAME and is in the current directory
FUNCTION_CODE_FOLDER_PATH="./${AZCF_NAME}"

# Name for the deployment package
ZIP_FILE_NAME="${AZCF_NAME}_package.zip"
# Path where the zip will be created (in the current directory)
ZIP_FILE_PATH="./${ZIP_FILE_NAME}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "Error: Not in a git repository. This script must be run from a git repository."
  exit 1
fi

# Compare the git repository root with the current working directory
if [ "$(pwd)" != "$REPO_ROOT" ]; then
  echo "Error: This script must be run from the repository root."
  echo "Current directory: $(pwd)"
  echo "Repository root:   $REPO_ROOT"
  echo "Please change to the repository root directory and try again."
  exit 1
fi

# --- Sanity Checks for required environment variables ---
if [ -z "$AZCF_RG" ]; then
  echo "Error: AZCF_RG environment variable is not set."
  exit 1
fi
if [ -z "$AZCF_NAME" ]; then
  echo "Error: AZCF_NAME environment variable is not set."
  exit 1
fi
if [ -z "$AZCF_LOCATION" ]; then
  echo "Error: AZCF_LOCATION environment variable is not set."
  exit 1
fi
if [ -z "$AZCF_ENV_SOMEVALUE" ]; then
  echo "Error: AZCF_ENV_SOMEVALUE environment variable is not set."
  exit 1
fi
if [ ! -d "$FUNCTION_CODE_FOLDER_PATH" ]; then
  echo "Error: Function code folder not found at $FUNCTION_CODE_FOLDER_PATH"
  echo "Please ensure a folder named '${AZCF_NAME}' with your function code exists in the current directory."
  exit 1
fi
if [ ! -f "$BICEP_FILE_PATH" ]; then
  echo "Error: Bicep file not found at $BICEP_FILE_PATH"
  exit 1
fi

echo "--- Configuration ---"
echo "Resource Group:         $AZCF_RG"
echo "Base Name (for Bicep):  $AZCF_NAME"
echo "Function App Name:      $FUNCTION_APP_RESOURCE_NAME"
echo "Location:               $AZCF_LOCATION"
echo "Bicep File:             $BICEP_FILE_PATH"
echo "Function Code Folder:   $FUNCTION_CODE_FOLDER_PATH"
echo "Zip Output Path:        $ZIP_FILE_PATH"
echo "AZCF_ENV_SOMEVALUE:     $AZCF_ENV_SOMEVALUE"
echo "---------------------"
echo ""

# 1. Deploy/Update Infrastructure with Bicep

# 2. Package Your Function App Code
# 3. Deploy Function App Code
echo "Deploying function code to Azure Function App: ${AZCF_NAME}..."
# Optional: Add a small delay if the Function App was *just* created by Bicep.
# This can sometimes help if the app isn't immediately ready for deployment.
# echo "Waiting for 30 seconds for Function App to initialize..."
# sleep 30

az functionapp deployment source config-zip \
  --resource-group "$AZCF_RG" \
  --name "${AZCF_NAME}-func" \
  --src "$ZIP_FILE_PATH" \
  --timeout 900 # Timeout in seconds for the deployment
echo "Function code deployment completed."
echo ""

# Optional: Clean up the local zip file
# echo "Cleaning up local zip file: $ZIP_FILE_PATH"
# rm "$ZIP_FILE_PATH"

echo "Deployment finished successfully!"
