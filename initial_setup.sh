#!/bin/bash

# Variables - Replace these with your actual values
PROJECT_ID="home-manager-438719"
BUCKET_NAME="orviss-homemanager-tfstate"
REGION="africa-south1"
SERVICE_ACCOUNT_NAME="terraform-sa"
GITHUB_ORG="prorviss"
REPO_NAME="home-manager"  # Just the repository name, without owner
REPO="$GITHUB_ORG/$REPO_NAME"  # Full GitHub repo in owner/repo format
LOCAL_DIR="terraform-base-config"

gcloud config set project "$PROJECT_ID"

# Ensure you are logged in to the GitHub CLI
if ! gh auth status > /dev/null 2>&1; then
    echo "Please authenticate with GitHub CLI by running: gh auth login"
    exit 1
fi

# Check if the GitHub repository already exists
if gh repo view "$REPO" > /dev/null 2>&1; then
    echo "Repository $REPO already exists."
else
    # Create the GitHub repository
    echo "Creating GitHub repository $REPO..."
    gh repo create "$REPO" --public --confirm
    echo "Repository $REPO created."
fi

# Enable necessary Google Cloud services
echo "Enabling Google Cloud services..."
gcloud services enable cloudresourcemanager.googleapis.com iam.googleapis.com storage.googleapis.com

# Create GCS bucket for Terraform state
echo "Creating GCS bucket for Terraform state..."
gsutil mb -p "$PROJECT_ID" -l "$REGION" gs://"$BUCKET_NAME"/
gsutil versioning set on gs://"$BUCKET_NAME"/

# Create Terraform service account
echo "Creating Terraform service account..."
gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
  --display-name "Terraform Service Account"

# Assign roles to the service account
echo "Assigning roles to the service account..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/editor"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# Create and download service account key
KEY_FILE="terraform-key.json"
echo "Creating and downloading service account key..."
gcloud iam service-accounts keys create "$KEY_FILE" \
  --iam-account "$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# Convert the service account key file into a base64-encoded string to securely pass it into GitHub secrets
BASE64_KEY=$(cat "$KEY_FILE" | base64)

# Add the base64-encoded key to GitHub Secrets using the GitHub CLI
echo "Uploading service account key to GitHub Secrets..."
gh secret set GOOGLE_CREDENTIALS --repo "$REPO" --body "$BASE64_KEY"

# Store the GCP Project ID in GitHub Secrets
gh secret set GCP_PROJECT --repo "$REPO" --body "$PROJECT_ID"

# Clean up the key file
echo "Cleaning up key file..."
rm "$KEY_FILE"

# Creating the base Terraform configuration
echo "Creating base Terraform configuration in $LOCAL_DIR..."

# Make the folder structure
mkdir -p "$LOCAL_DIR"

# Create backend.tf for remote state storage
cat > "$LOCAL_DIR/backend.tf" <<EOL
terraform {
  backend "gcs" {
    bucket  = "$BUCKET_NAME"
    prefix  = "terraform/state"
    project = "$PROJECT_ID"
  }
}
EOL

# Create main.tf
cat > "$LOCAL_DIR/main.tf" <<EOL
provider "google" {
  project     = var.project_id
  region      = var.region
}

resource "google_storage_bucket" "example_bucket" {
  name     = "example-terraform-bucket-\${var.project_id}"
  location = var.region
}
EOL

# Create variables.tf
cat > "$LOCAL_DIR/variables.tf" <<EOL
variable "project_id" {
  description = "The project ID to deploy resources in"
  type        = string
}

variable "region" {
  description = "Google Cloud region"
  type        = string
  default     = "$REGION"
}
EOL

# Create .gitignore
cat > "$LOCAL_DIR/.gitignore" <<EOL
# Ignore Terraform state files
*.tfstate
*.tfstate.backup
.terraform/

# Ignore service account keys
terraform-key.json
EOL

# Initialize Terraform to configure the backend
cd "$LOCAL_DIR"
terraform init

# Git setup and commit the Terraform configuration
git init
git remote add origin "git@github.com:$REPO.git"
git add .
git commit -m "Initial commit of base Terraform configuration"
git branch -M main
git push -u origin main

echo "Terraform configuration has been initialized and pushed to $REPO."

echo "Setup complete. Google Cloud service account key and project ID have been stored as GitHub Secrets."