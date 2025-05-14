#!/bin/bash

# Exit on any error to prevent unexpected behavior
# set -e
# Optional: uncomment to see each command being executed
# set -x

# Get Project from Environment Variable
echo "--- Initial Variable Check ---"
if [ -z "$AZCF_PROJECT" ]; then
    echo "FATAL: AZCF_PROJECT environment variable is not set or is empty."
    echo "Please ensure direnv loaded it correctly ('direnv allow .' and check 'echo \$AZCF_PROJECT')."
    exit 1
fi
project="$AZCF_PROJECT"

if [ -z "$project" ]; then
    echo "FATAL: \$project variable became empty immediately after assignment from AZCF_PROJECT. This is unexpected."
    exit 1
fi

echo "Using Azure DevOps Project: $project"

pipeline_yaml_file="azure-pipelines.yml"
variable_prefix="AZCF_"
secret_indicator="SEC" # Variables containing this string will be marked as secret

# --- Argument Parsing ---
is_update_mode=false
if [[ "$1" == "--update" ]]; then
  is_update_mode=true
  echo "Running in --update mode. Existing resources will be updated where possible."
else
  echo "Running in initial setup mode. Will attempt to create resources."
fi

# --- Prerequisite Checks ---
echo "--- Prerequisite Checks ---"

# Check az CLI
if ! command -v az &> /dev/null; then
    echo "FATAL: Azure CLI (az) is not installed. Please install it and try again."
    exit 1
fi

# Check func CLI
if ! command -v func &> /dev/null; then
    echo "FATAL: Azure functions core tools (func) is not installed. Please install it and try again."
    exit 1
fi

# Check Azure DevOps Extension
if ! az extension show --name azure-devops &> /dev/null; then
    echo "Azure DevOps CLI extension not found. Installing..."
    if ! az extension add --name azure-devops; then
        echo "FATAL: Failed to install Azure DevOps extension."
        exit 1
    fi
fi

# --- Azure Login & DevOps Setup ---
echo "--- Azure Login & DevOps Setup ---"
echo "Checking Azure login status..."
if ! az account show &> /dev/null; then
    echo "Not logged into Azure. Run 'az login' and try again."
else
    echo "Already logged into Azure."
fi

if [ -z "$AZCF_ORGANISATION" ]; then
    echo "FATAL: AZCF_ORGANISATION environment variable is not set."
    echo "Please set it to your Azure DevOps organization name."
    exit 1
fi
# Check if Azure DevOps PAT is set
if [ -z "$AZURE_DEVOPS_EXT_PAT" ]; then
    echo "WARNING: AZURE_DEVOPS_EXT_PAT environment variable is not set."
    echo "This Personal Access Token is required for Azure DevOps operations."
    echo "Please set it to a valid Azure DevOps PAT with appropriate permissions."
    echo "For more information, visit: https://docs.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate"

    exit 1
fi

organization_url="https://dev.azure.com/$AZCF_ORGANISATION/"
echo "Using Azure DevOps Organization: $organization_url"

# --- Check if Project Exists and Optionally Create --- BGN
echo "--- Check if Project Exists ---"

# Check if project variable is empty *here*
if [ -z "$project" ]; then
    echo "FATAL: \$project variable is empty at the point of checking project existence."
    echo "It was likely overwritten or unset somewhere between the initial assignment and here."
    exit 1
fi

echo "Checking if Azure DevOps project '$project' exists in organization '$AZCF_ORGANISATION'..."
# Explicitly specify the organization for this check
# Add --debug flag for maximum verbosity from Azure CLI if needed again
project_check_output=$(az devops project show --project "$project" --organization "$organization_url" --query name -o tsv 2>&1)
project_exists_status=$?

# Add the variable value to the error message too for clarity
if [ $project_exists_status -ne 0 ]; then
    echo "Project '$project' (variable value was '$project') does not seem to exist in organization '$AZCF_ORGANISATION'."
    echo "Error from Azure CLI: $project_check_output"
    # Check if running non-interactively (e.g., in a pipeline)
    if [ -t 1 ]; then # Check if stdout is a terminal
      read -p "Do you want to create it? (y/N): " create_project_response
      # Convert response to lowercase
      create_project_response_lower=${create_project_response,,}
    else
      echo "Running non-interactively. Cannot create project. Please ensure project exists or run interactively."
      exit 1
      # Or default to 'n' if preferred:
      # create_project_response_lower="n"
    fi


    if [[ "$create_project_response_lower" == "y" || "$create_project_response_lower" == "yes" ]]; then
        echo "Attempting to create project '$project' in organization '$organization_url'..."
        # Explicitly specify organization during creation too
        if az devops project create --name "$project" --organization "$organization_url"; then
            echo "Project '$project' created successfully."
            # Configure defaults now that the project is created
            echo "Configuring Azure DevOps defaults for the new project..."
            az devops configure --defaults organization="$organization_url" project="$project"
            if [ $? -ne 0 ]; then
                echo "FATAL: Failed to configure Azure DevOps defaults after creating the project."
                exit 1
            fi
        else
            echo "FATAL: Failed to create project '$project'."
            exit 1
        fi
    else
        echo "Aborting script because project '$project' does not exist and was not created."
        exit 1
    fi
else
    echo "Project '$project' found in organization '$AZCF_ORGANISATION'."
    # Configure defaults now that we know the project exists
    echo "Configuring Azure DevOps defaults..."
    az devops configure --defaults organization="$organization_url" project="$project"
    if [ $? -ne 0 ]; then
        echo "FATAL: Failed to configure Azure DevOps defaults. Check organization and project names."
        exit 1
    fi
fi
# --- Check if Project Exists and Optionally Create --- END

# --- Azure Service Connection Setup ---
echo "--- Azure Service Connection Setup ---"
# Use a project-based name, as the connection is project-scoped
service_connection_name="${project}-Default-ARM-Connection"
echo "Setting up Azure Resource Manager service connection: $service_connection_name"

# Get Azure Subscription Details
echo "Fetching Azure subscription details..."
# Use double quotes for the query for better shell compatibility
azure_sub_details=$(az account show --query "{id: id, name: name, tenantId: tenantId}" -o json)
if [ $? -ne 0 ] || [ -z "$azure_sub_details" ]; then
    echo "FATAL: Failed to retrieve Azure subscription details. Ensure you are logged in ('az login') and have selected a subscription ('az account set --subscription ...')."
    exit 1
fi
azure_sub_id=$(echo "$azure_sub_details" | grep -o '"id": "[^"]*' | grep -o '[^:"]*$')
azure_sub_name=$(echo "$azure_sub_details" | grep -o '"name": "[^"]*' | grep -o '[^:"]*$')
azure_tenant_id=$(echo "$azure_sub_details" | grep -o '"tenantId": "[^"]*' | grep -o '[^:"]*$')

echo "Using Subscription ID: $azure_sub_id"
echo "Using Subscription Name: $azure_sub_name"
echo "Using Tenant ID: $azure_tenant_id"

# Check if service connection already exists
echo "Checking for existing service connection '$service_connection_name'..."
endpoint_id=$(az devops service-endpoint list --project "$project" --organization "$organization_url" --query "[?name=='$service_connection_name' && type=='azurerm'].id" -o tsv 2>/dev/null)

if [ -n "$endpoint_id" ]; then
    echo "Service connection '$service_connection_name' already exists (ID: $endpoint_id)."
    # Ensure it's authorized for all pipelines
    echo "Ensuring connection is authorized for all pipelines..."
    az devops service-endpoint update --id "$endpoint_id" --enable-for-all true --project "$project" --organization "$organization_url" > /dev/null
    if [ $? -ne 0 ]; then
        echo "WARNING: Failed to ensure authorization for existing service connection '$service_connection_name'."
    else
        echo "Service connection authorized."
    fi
else
    echo "Service connection '$service_connection_name' not found. Creating..."

    # 1. Create Azure Service Principal explicitly
    echo "Creating Azure Service Principal..."
    # The SP name will be based on the service connection name for easier identification
    sp_name="http://${service_connection_name}"
    # Use --years 2 for longer validity, adjust if needed
    # Capture output as JSON
    sp_details=$(az ad sp create-for-rbac --name "$sp_name" --role Contributor --scopes "/subscriptions/$azure_sub_id" --years 2 --output json)
    if [ $? -ne 0 ] || [ -z "$sp_details" ]; then
        echo "FATAL: Failed to create Azure Service Principal '$sp_name'."
        echo "Check Azure permissions (e.g., Application Administrator or Global Administrator role in Azure AD)."
        exit 1
    fi

    # Extract details from JSON output
    service_principal_id=$(echo "$sp_details" | grep -o '"appId": "[^"]*' | grep -o '[^:"]*$')
    service_principal_key=$(echo "$sp_details" | grep -o '"password": "[^"]*' | grep -o '[^:"]*$')
    sp_tenant_id=$(echo "$sp_details" | grep -o '"tenant": "[^"]*' | grep -o '[^:"]*$')

    if [ -z "$service_principal_id" ] || [ -z "$service_principal_key" ] || [ -z "$sp_tenant_id" ]; then
        echo "FATAL: Failed to extract Service Principal details from creation output."
        exit 1
    fi

    echo " -> Service Principal created successfully. App ID: $service_principal_id"
    # DO NOT echo the key here
    # Verify the tenant matches the subscription tenant
    if [ "$sp_tenant_id" != "$azure_tenant_id" ]; then
      echo "WARNING: Service Principal tenant ('$sp_tenant_id') does not match subscription tenant ('$azure_tenant_id'). This might cause issues."
    fi

    # 2. Create Azure DevOps service connection using the SP credentials
    echo "Creating Azure DevOps service connection '$service_connection_name' using the created SP..."
    echo "Setting service principal key as environment variable and executing command..."

    # Set the service principal key as an environment variable
    export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY="$service_principal_key"

    create_output=$(az devops service-endpoint azurerm create --name "$service_connection_name" \
                             --azure-rm-service-principal-id "$service_principal_id" \
                             --azure-rm-subscription-id "$azure_sub_id" \
                             --azure-rm-subscription-name "$azure_sub_name" \
                             --azure-rm-tenant-id "$azure_tenant_id" \
                             --project "$project" \
                             --organization "$organization_url" --output json)

    # Unset the environment variable for security
    unset AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY

    if [ $? -ne 0 ] || [ -z "$create_output" ]; then
        echo "FATAL: Failed to create Azure RM service connection '$service_connection_name' using SP details."
        # Consider deleting the created SP if endpoint creation fails? Optional.
        # az ad sp delete --id $service_principal_id
        exit 1
    fi

    new_endpoint_id=$(echo "$create_output" | grep -o '"id": "[^"]*' | grep -o '[^:"]*$')
    # SP ID already stored in service_principal_id

    echo "Service connection '$service_connection_name' (ID: $new_endpoint_id) created successfully."
    echo " -> Associated Service Principal ID: $service_principal_id"

    # Authorize for all pipelines
    echo "Authorizing connection for all pipelines..."
    az devops service-endpoint update --id "$new_endpoint_id" --enable-for-all true --project "$project" --organization "$organization_url" > /dev/null
    if [ $? -ne 0 ]; then
        echo "WARNING: Failed to authorize the new service connection '$service_connection_name' for all pipelines."
    else
        echo "Service connection authorized."
    fi

    echo ""
    echo "IMPORTANT: A Service Principal ($service_principal_id) was created in Azure AD for this connection."
    echo "If your pipeline needs to deploy/modify Azure resources, you MUST grant this Service Principal appropriate Azure roles (e.g., Contributor) on your subscription ($azure_sub_id) or target resource group."
    echo "You can do this via the Azure portal or Azure CLI (e.g., 'az role assignment create --assignee $service_principal_id --role Contributor --scope /subscriptions/$azure_sub_id')."
    echo ""

fi

echo "Service Connection setup complete."
echo "Ensure your '$pipeline_yaml_file' uses the following service connection name:"
echo "  $service_connection_name"
echo ""

# --- Repository Setup ---
echo "--- Repository Setup ---"
repo_name=$(basename "$PWD")
echo "Working with repository: $repo_name"

if [ "$is_update_mode" = false ]; then
    echo "Performing initial repository setup..."
    # Initialize local git repo
    if [ -d .git ]; then
      echo "Local .git directory already exists."
    else
      echo "Initializing local git repository..."
      git init
      # Create README if it doesn't exist
      if [ ! -f README.md ]; then
          echo "# $repo_name" > README.md
          echo "Created README.md"
          git add README.md
      fi
      # Create tests dir if it doesn't exist
      mkdir -p tests
      # Add other essential files if they exist (e.g., .gitignore, initial code)
      git add .
      git commit -m "Initial commit by setup script" --allow-empty # Allow empty if only README was added
      git branch -M main
      echo "Local git repository initialized."
    fi

    # Check if Azure DevOps repo exists
    echo "Checking if Azure DevOps repository '$repo_name' exists..."

    # Temporarily disable exit on error for this sensitive command
    set +e
    # Capture combined output (stdout and stderr) from the az command
    # Storing the output directly into a variable instead of temporary files.
    raw_repo_show_output=$(az repos show --repository "$repo_name" --project "$project" --organization "$organization_url" --query sshUrl -o tsv 2>&1)
    repo_check_status=$?
    # Re-enable exit on error as soon as possible
    set -e

    # Initialize variables that were previously read from files
    repo_ssh_url_from_check=""
    repo_error_from_check="" # This will hold the error if the command failed

    if [ "$repo_check_status" -eq 0 ]; then
        # Command succeeded, output is the SSH URL.
        # az ... -o tsv should ensure clean output on stdout.
        repo_ssh_url_from_check="$raw_repo_show_output"
    else
        # Command failed, output is the error message.
        repo_error_from_check="$raw_repo_show_output"
        # repo_ssh_url_from_check remains empty as intended on failure.
    fi

    # If status is non-zero (command failed) OR stderr contains "does not exist"
    if [ "$repo_check_status" -ne 0 ] || echo "$repo_error_from_check" | grep -q "does not exist"; then
        echo "Azure DevOps repository '$repo_name' not found. Creating..."
        # Create repo first
        az repos create --name "$repo_name" --project "$project" --organization "$organization_url"
        # if [ $? -ne 0 ] || [ -z "$create_output" ]; then
        #     echo "FATAL: Failed to create Azure DevOps repository. - Error: $create_output"
        #     exit 1
        # fi
        # Now fetch the SSH URL
        repo_ssh_url=$(az repos show --repository "$repo_name" --project "$project" --organization "$organization_url" --query sshUrl -o tsv)
        if [ $? -ne 0 ] || [ -z "$repo_ssh_url" ]; then
            echo "FATAL: Failed to retrieve SSH URL for the newly created Azure DevOps repository."
            exit 1
        fi
        echo "Azure DevOps repository created. SSH URL: $repo_ssh_url"

        # Check if origin remote already exists
        if git remote get-url origin > /dev/null 2>&1; then
            echo "Git remote 'origin' already exists. Setting URL to SSH..."
            git remote set-url origin "$repo_ssh_url"
        else
            echo "Adding git remote 'origin' with SSH URL..."
            git remote add origin "$repo_ssh_url"
        fi

        echo "Pushing initial commit to origin/main via SSH..."
        git push -u origin main
        if [ $? -ne 0 ]; then
            echo "WARNING: Failed to push initial commit via SSH. Please ensure your SSH key is added to Azure DevOps and has permissions."
        fi
    else
        # Repo exists, use the sshUrl obtained from the check
        repo_ssh_url="$repo_ssh_url_from_check"
        echo "Azure DevOps repository '$repo_name' already exists. SSH URL: $repo_ssh_url"
        # Ensure local remote matches the SSH URL
        local_remote_url=$(git remote get-url origin 2>/dev/null || true)
        if [ "$local_remote_url" != "$repo_ssh_url" ]; then
             echo "Updating local git remote 'origin' URL to SSH..."
             if git remote get-url origin > /dev/null 2>&1; then
                 git remote set-url origin "$repo_ssh_url"
             else
                 git remote add origin "$repo_ssh_url"
             fi
        else
             echo "Local git remote 'origin' is already set to the correct SSH URL."
        fi
    fi
else # --- This is the --update mode block ---
    echo "Skipping repository creation/initialization (--update mode)."
    # Optionally, ensure remote exists and is correct even in update mode
    echo "Ensuring remote 'origin' is set to the correct SSH URL..."
    repo_ssh_url=$(az repos show --repository "$repo_name" --project "$project" --organization "$organization_url" --query sshUrl -o tsv 2>/dev/null)
     if [ -z "$repo_ssh_url" ]; then
        echo "ERROR: Cannot find Azure DevOps repository '$repo_name' in --update mode."
        # If the repo doesn't exist in update mode, we can't really proceed with remote setup
     else
        # Allow this command to fail without exiting the script (due to set -e)
        # If 'origin' doesn't exist, local_remote_url will be empty.
        local_remote_url=$(git remote get-url origin 2>/dev/null || true)
        if [ "$local_remote_url" != "$repo_ssh_url" ]; then
             echo "Updating local git remote 'origin' URL to SSH..."
             if git remote get-url origin > /dev/null 2>&1; then
                 git remote set-url origin "$repo_ssh_url"
             else
                 git remote add origin "$repo_ssh_url"
             fi
        else
            echo "Local remote 'origin' is already up to date with the SSH URL."
        fi
     fi
fi

# --- Variable Group Setup ---
echo "--- Variable Group Setup ---"
variable_group_name="${repo_name}-variables"
echo "Setting up variable group: $variable_group_name"

# Check if variable group exists
echo "Checking for existing variable group..."
group_id=$(az pipelines variable-group list --group-name "$variable_group_name" --project "$project" --organization "$organization_url" --query "[0].id" -o tsv 2>/dev/null)
dummy_variable_created=false # Flag to track if we added the dummy variable

if [ -z "$group_id" ]; then
  echo "Variable group '$variable_group_name' not found. Creating..."
  # Create with a dummy variable first
  group_id=$(az pipelines variable-group create --name "$variable_group_name" --project "$project" --organization "$organization_url" --variables dummy=temp --authorize true --query id -o tsv)
  if [ $? -ne 0 ] || [ -z "$group_id" ]; then
      echo "FATAL: Failed to create variable group '$variable_group_name'."
      exit 1
  fi
  echo "Variable group created with ID: $group_id."
  dummy_variable_created=true # Mark that we created the dummy var
  # DO NOT remove the dummy variable here yet
else
   echo "Variable group '$variable_group_name' already exists (ID: $group_id)."
   # Ensure authorization is set on existing group
   az pipelines variable-group update --group-id "$group_id" --project "$project" --organization "$organization_url" --authorize true > /dev/null
   if [ $? -ne 0 ]; then
       echo "WARNING: Failed to ensure authorization on existing variable group."
   fi

   # Update existing variables in update mode
   if [ "$is_update_mode" = true ]; then
     echo "Update mode enabled. Updating variables in existing variable group..."

     # Process environment variables with the specified prefix
     all_env_vars=$(printenv | grep "^${variable_prefix}" | awk -F'=' '{print $1}')
     if [ -z "$all_env_vars" ]; then
       echo "No environment variables found with prefix '$variable_prefix' to update."
     else
       for var_name in $all_env_vars; do
         var_value=$(printenv "$var_name")
         is_secret=false
         if [[ "$var_name" == *"$secret_indicator"* ]]; then
           is_secret=true
         fi

         # Update the variable
         az pipelines variable-group variable update --group-id "$group_id" --project "$project" --organization "$organization_url" \
           --name "$var_name" --value "$var_value" --secret $is_secret > /dev/null 2>&1

         if [ $? -ne 0 ]; then
           # If update failed (likely because it doesn't exist), create it
           echo " -> Variable not found. Creating new variable '$var_name'..."
           az pipelines variable-group variable create --group-id "$group_id" --project "$project" --organization "$organization_url" \
             --name "$var_name" --value "$var_value" --secret $is_secret
           if [ $? -ne 0 ]; then
             echo "    WARNING: Failed to create variable '$var_name' in group '$variable_group_name'."
           else
             echo "    -> Variable '$var_name' created."
           fi
         else
           echo " -> Variable '$var_name' updated successfully."
         fi
       done
     fi
   fi
fi

# Add/Update the Service Principal Key if it was generated
if [ -n "$service_principal_key" ]; then
  sp_key_var_name="AZCF_${secret_indicator}_SP_PASSWORD" # Construct variable name
  echo "Adding/Updating Service Principal Key ('$sp_key_var_name') in variable group..."
  az pipelines variable-group variable update --group-id "$group_id" --project "$project" --organization "$organization_url" \
    --name "$sp_key_var_name" --value "$service_principal_key" --secret true > /dev/null 2>&1
  if [ $? -ne 0 ]; then
     echo " -> SP Key not found or update failed. Creating..."
     az pipelines variable-group variable create --group-id "$group_id" --project "$project" --organization "$organization_url" \
       --name "$sp_key_var_name" --value "$service_principal_key" --secret true
     if [ $? -ne 0 ]; then
         echo "    WARNING: Failed to create variable '$sp_key_var_name' in group '$variable_group_name'."
     else
         echo "    -> Variable '$sp_key_var_name' created."
     fi
  else
      echo " -> Variable '$sp_key_var_name' updated."
  fi
else
  # This case might happen in --update mode if the connection already existed
  echo "Skipping SP Key update in variable group (key not generated in this run)."
fi

# Now, attempt to remove the dummy variable only if we created it AND added/updated other vars
if [ "$dummy_variable_created" = true ]; then
    if [ "$variables_added_count" -gt 0 ]; then
        echo "Removing dummy variable..."
        az pipelines variable-group variable delete --group-id "$group_id" --project "$project" --organization "$organization_url" --name dummy --yes > /dev/null
        if [ $? -ne 0 ]; then
            echo "WARNING: Failed to remove dummy variable. It might have already been removed or another issue occurred."
        else
            echo "Dummy variable removed."
        fi
    else
        echo "WARNING: No other variables were added/updated in the group. Keeping the dummy variable to avoid errors."
    fi
fi

echo "Variable group setup complete."
echo "Add the following to your $pipeline_yaml_file to use these variables:"
echo ""
echo "variables:"
echo "  - group: $variable_group_name"
echo ""

# --- Pipeline Setup ---
echo "--- Pipeline Setup ---"
pipeline_name="${repo_name}-ci" # Or adjust naming convention
echo "Setting up pipeline: $pipeline_name"

# Check if the pipeline YAML file exists
if [ ! -f "$pipeline_yaml_file" ]; then
    echo "WARNING: Pipeline definition file '$pipeline_yaml_file' not found in the current directory."
    echo "Please create '$pipeline_yaml_file' before the pipeline can be fully configured."
    # Optionally: copy a template file here if in create mode
    # if [ "$is_update_mode" = false ]; then
    #    cp /path/to/template-azure-pipelines.yml "$pipeline_yaml_file"
    #    git add "$pipeline_yaml_file"
    #    git commit -m "Add pipeline definition template"
    #    git push origin main
    # fi
else
    echo "Found pipeline definition file: $pipeline_yaml_file"
    # Check if pipeline exists in Azure DevOps
    echo "Checking for existing pipeline '$pipeline_name'..."
    pipeline_id=$(az pipelines show --name "$pipeline_name" --project "$project" --organization "$organization_url" --query id -o tsv 2>/dev/null || true)

    if [ -z "$pipeline_id" ]; then
      echo "Pipeline '$pipeline_name' not found. Creating..."
      az pipelines create --name "$pipeline_name" \
                          --repository "$repo_name" \
                          --branch "main" \
                          --yml-path "$pipeline_yaml_file" \
                          --repository-type tfsgit \
                          --project "$project" \
                          --organization "$organization_url" \
                          --skip-first-run true # Don't run immediately after creation
      if [ $? -ne 0 ]; then
          echo "ERROR: Failed to create pipeline '$pipeline_name'. Check logs and permissions."
          # It might fail if the YAML file hasn't been pushed yet.
          echo "Ensure '$pipeline_yaml_file' is committed and pushed to the 'main' branch in Azure Repos."
      else
          echo "Pipeline '$pipeline_name' created successfully."
      fi
    else
      echo "Pipeline '$pipeline_name' already exists (ID: $pipeline_id)."
      # For YAML pipelines, 'update' via CLI isn't usually needed as the definition is in the file.
      # You could add checks here to ensure it points to the right repo/branch/yaml file if needed.
      # az pipelines update --id $pipeline_id --branch main ... (if necessary)
    fi
fi

# --- Template Generation ---
echo "--- Template Generation ---"
# Assuming you have a variable containing your service connection name
# For example: SERVICE_CONNECTION_NAME="my-azure-connection"

# Check if service endpoint exists or was created successfully
# Use the variable 'service_connection_name' defined earlier
if az devops service-endpoint list --project "$project" --organization "$organization_url" --query "[?name=='$service_connection_name']" --output tsv | grep -q "$service_connection_name"; then
    echo "Service connection '$service_connection_name' exists."
    if [ -f "azure-pipelines.tpl.yml" ]; then
        echo "Found template file 'azure-pipelines.tpl.yml'. Generating '$pipeline_yaml_file'..."
        # Replace the placeholder with the actual service connection name in the template
        sed "s/#AZURE_SERVICE_CONNECTION#/$service_connection_name/g" azure-pipelines.tpl.yml > "$pipeline_yaml_file"
        # Add a warning comment at the top of the file
        # Use a temporary file for sed -i compatibility on macOS and Linux
        sed -i.bak '1i\
# WARNING: This file is auto-generated by setup-repo.sh. Any changes made directly to this file may be overwritten.\
# To make permanent changes, edit azure-pipelines.tpl.yml instead.
' "$pipeline_yaml_file" && rm "${pipeline_yaml_file}.bak" # Remove backup file on success

        echo "Created/Updated '$pipeline_yaml_file' with service connection name '$service_connection_name' from template."
    else
        echo "WARNING: Template file 'azure-pipelines.tpl.yml' not found. Skipping generation of '$pipeline_yaml_file'."
    fi
else
    echo "WARNING: Service connection '$service_connection_name' does not seem to exist. Skipping generation/update of '$pipeline_yaml_file'."
fi


echo "--- Setup Script Finished ---"
