#!/bin/bash

# WARNING: Please be sure to delete any existing GitHub action workflows in the repo before running this script.
# Failure to do so will create conflicts between existing and new workflows created by this script
# and result in unexpected build and deploy behavior.

# To make this script executable, run the following command:
# chmod +x azContainerApps_worker.sh
# Execute with ./azContainerApps_worker.sh


# Define color codes
YELLOW='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where the script is located
script_dir=$(dirname "$0")

# Change to the script directory
cd "$script_dir" || exit

# Initialize configuration variable
config_found=false

# Traverse up the directory tree to find globalenv.config
dir=$(pwd)
while [[ "$dir" != "/" ]]; do
  if [[ -f "$dir/globalenv.config" ]]; then
    source "$dir/globalenv.config"
    config_found=true
    break
  fi
  dir=$(dirname "$dir")
done

# Exit if globalenv.config was not found
if [ "$config_found" = false ]; then
    echo -e "${RED}Error: globalenv.config not found.${NC}"
    exit 1
fi

# Use variables from configuration file
envPrefix=$ENVIRONMENT_PREFIX
projectPrefix=$PROJECT_PREFIX
projectResourceGroupName="$PROJECT_RESOURCE_GROUP"
projectLocation=$PROJECT_LOCATION
log_folder=$LOG_FOLDER
log_file="$log_folder/deploy_worker.log"

# Set Project Subscription ID
projectSubscriptionID=$PROJECT_SUBSCRIPTION_ID

# Set the desired Azure Container Apps environment details
environmentName="${envPrefix}-${projectPrefix}-BackendContainerAppsEnv"
containerAppName="${envPrefix}-${projectPrefix}-yourworkername"
registryUrl="${envPrefix}${projectPrefix}contregistry.azurecr.io"

# Set additional variables
repoUrl="https://github.com/CollinsMunene-Developer/meru-innov-deploy"
branch="main"

# MAIN LOGIC ============================================================================

# Redirect output to log file
exec > >(tee -a "$log_file") 2>&1

echo -e "Deploying with Environment Prefix | Project Prefix: ${YELLOW}${envPrefix} | ${projectPrefix}${NC}"
echo -e "Deploying to Resource Group: ${YELLOW}$projectResourceGroupName${NC}"
echo -e "Deploying to Location: ${YELLOW}$projectLocation${NC}"
echo -e "Log folder location: ${YELLOW}$log_folder${NC}"

# Check if already logged in with az
if az account show &>/dev/null; then
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}Already logged in to Azure CLI.${NC}"
else
  # Prompt for login
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}Not logged in to Azure CLI. Please log in.${NC}"
  az login
fi

# Set the default subscriptionj
az account set --subscription "$projectSubscriptionID"

# Confirm the current subscription is set to the desired one
current_subscription=$(az account show --query id -o tsv)
if [[ "$current_subscription" != "$projectSubscriptionID" ]]; then
  echo -e "${RED}Error: Failed to set the Azure subscription. Current subscription: $current_subscription${NC}"
  exit 1
fi

# Create the container app using az containerapp up
echo -e "${BLUE}Creating or updating container app '${containerAppName}'...${NC}"
az containerapp up \
    --name "$containerAppName" \
    --resource-group "$projectResourceGroupName" \
    --environment "$environmentName" \
    --repo "$repoUrl" \
    --branch "$branch" \
    --registry-server "$registryUrl" \
    --ingress external \
    --target-port 8080

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create or update container app '${containerAppName}'.${NC}"
    exit 1
fi

echo -e "${GREEN}Container app '$containerAppName' created or updated successfully.${NC}"

# Update the container app with the required settings
echo -e "${BLUE}Updating container app '${containerAppName}' with CPU, memory, and scaling settings...${NC}"
az containerapp update \
    --name "$containerAppName" \
    --resource-group "$projectResourceGroupName" \
    --cpu 0.25 \
    --memory 0.5Gi \
    --min-replicas 1 \
    --max-replicas 10

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to update container app '${containerAppName}'.${NC}"
    exit 1
fi

echo -e "${GREEN}Container app '$containerAppName' updated successfully.${NC}"

# Disable ingress for the container app
echo -e "${BLUE}Disabling ingress for the container app '${containerAppName}'...${NC}"
az containerapp ingress disable --name "$containerAppName" --resource-group "$projectResourceGroupName"

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to disable ingress for container app '${containerAppName}'.${NC}"
    exit 1
fi

echo -e "${GREEN}Ingress disabled successfully.${NC}"

echo -e "${GREEN}Deployment completed successfully.${NC}"