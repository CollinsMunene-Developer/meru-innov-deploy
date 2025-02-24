#!/bin/bash

# WARNING: Please be sure to delete any existing GitHub action workflows in the repo before running this script.
# Failure to do so will create conflicts between existing and new workflows created by this script
# and result in unexpected build and deploy behavior.

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
registryName="${envPrefix}${projectPrefix}contregistry"
registryUrl="${registryName}.azurecr.io"

# Set additional variables
repoUrl="$GITHUB_REPO_URL"
branch="$GITHUB_BRANCH"

# MAIN LOGIC ============================================================================

# Create log directory if it doesn't exist
mkdir -p "$log_folder"

# Redirect output to log file
exec > >(tee -a "$log_file") 2>&1

echo -e "Deploying with Environment Prefix | Project Prefix: ${YELLOW}${envPrefix} | ${projectPrefix}${NC}"
echo -e "Deploying to Resource Group: ${YELLOW}$projectResourceGroupName${NC}"
echo -e "Deploying to Location: ${YELLOW}$projectLocation${NC}"
echo -e "Log folder location: ${YELLOW}$log_folder${NC}"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker is not installed. Installing Docker...${NC}"
    
    # Check if we are in a devcontainer
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        echo -e "${YELLOW}Running in a container. Installing Docker CLI only...${NC}"
        
        # Install Docker CLI in the devcontainer
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce-cli
    else
        # Install full Docker for local environment
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo usermod -aG docker $USER
        echo -e "${YELLOW}Please log out and log back in for Docker permissions to take effect.${NC}"
    fi
fi

# Check if already logged in with az
if az account show &>/dev/null; then
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}Already logged in to Azure CLI.${NC}"
else
  # Prompt for login
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}Not logged in to Azure CLI. Please log in.${NC}"
  az login
fi

# Set the default subscription
az account set --subscription "$projectSubscriptionID"

# Confirm the current subscription is set to the desired one
current_subscription=$(az account show --query id -o tsv)
if [[ "$current_subscription" != "$projectSubscriptionID" ]]; then
  echo -e "${RED}Error: Failed to set the Azure subscription. Current subscription: $current_subscription${NC}"
  exit 1
fi

# Create resource group if it doesn't exist
if ! az group show --name "$projectResourceGroupName" &>/dev/null; then
  echo -e "${BLUE}Creating resource group '$projectResourceGroupName'...${NC}"
  az group create --name "$projectResourceGroupName" --location "$projectLocation"
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create resource group '$projectResourceGroupName'.${NC}"
    exit 1
  fi
fi

# Create container registry if it doesn't exist
if ! az acr show --name "$registryName" --resource-group "$projectResourceGroupName" &>/dev/null; then
  echo -e "${BLUE}Creating container registry '$registryName'...${NC}"
  az acr create --name "$registryName" --resource-group "$projectResourceGroupName" --sku Basic --admin-enabled true
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create container registry '$registryName'.${NC}"
    exit 1
  fi
fi

# Get container registry credentials
echo -e "${BLUE}Retrieving container registry credentials...${NC}"
registry_username=$(az acr credential show --name "$registryName" --resource-group "$projectResourceGroupName" --query "username" -o tsv)
registry_password=$(az acr credential show --name "$registryName" --resource-group "$projectResourceGroupName" --query "passwords[0].value" -o tsv)

if [[ -z "$registry_username" || -z "$registry_password" ]]; then
  echo -e "${RED}Failed to retrieve container registry credentials.${NC}"
  exit 1
fi

echo -e "${GREEN}Container registry credentials retrieved successfully.${NC}"

# Create the container app using az containerapp up
echo -e "${BLUE}Creating or updating container app '${containerAppName}'...${NC}"
az containerapp up \
    --name "$containerAppName" \
    --resource-group "$projectResourceGroupName" \
    --environment "$environmentName" \
    --repo "$repoUrl" \
    --branch "$branch" \
    --registry-server "$registryUrl" \
    --registry-username "$registry_username" \
    --registry-password "$registry_password" \
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