#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Because everything is created inside a single dedicated project
# ("CSIS-CSA-Resources"), the whole deployment can be torn down at any time
# simply by deleting that project.

PROJECT_NAME="CSIS-CSA-Resources"
SA_ACCOUNT_ID="csis-csa-collector"
POOL_ID="csis-identity-pool"
PROVIDER_ID="csis-cert-provider"
TRUST_ANCHOR_FILE="trust_anchor.pem"
TRUST_STORE_CONFIG_FILE=".trust_store_config.generated.yaml"

GCP_SERVICES=(
    "cloudresourcemanager.googleapis.com"
    "iam.googleapis.com"
    "logging.googleapis.com"
    "cloudasset.googleapis.com"
    "serviceusage.googleapis.com"
    "essentialcontacts.googleapis.com"
    "securitycenter.googleapis.com"
    "storage.googleapis.com"
    # "run.googleapis.com"
    "admin.googleapis.com"
    "cloudidentity.googleapis.com"
    "apikeys.googleapis.com"
)

ROLE_PERMISSIONS="essentialcontacts.contacts.list,iam.accesspolicies.list,iam.policybindings.list,iam.roles.list,iam.serviceAccountKeys.list,iam.serviceAccounts.list,logging.logEntries.list,logging.logs.list,resourcemanager.projects.get,serviceusage.services.list,storage.buckets.list,storage.hmacKeys.list"

echo "===================================================="
echo " Checking GCP Authentication..."
echo "===================================================="
# Ensure the user is authenticated
gcloud auth application-default print-access-token &>/dev/null || {
    echo "You are not authenticated. Running 'gcloud auth application-default login'..."
    gcloud auth application-default login
}

# 1. Select Organization
echo ""
echo "===================================================="
echo " Fetching available Organizations..."
echo "===================================================="

# Fetch orgs and parse into arrays
orgs=()
org_ids=()
while read -r name id; do
    if [[ -n "$name" && -n "$id" ]]; then
        orgs+=("$name")
        org_ids+=("$id")
    fi
done < <(gcloud organizations list --format="value(displayName,ID)")

if [ ${#orgs[@]} -eq 0 ]; then
    echo "ERROR: No organizations found. Ensure you have 'roles/resourcemanager.organizationViewer' permissions."
    exit 1
fi

echo "Please select the organization to audit:"
select opt in "${orgs[@]}"; do
    for i in "${!orgs[@]}"; do
        if [[ "${orgs[$i]}" == "$opt" ]]; then
            SELECTED_ORG_ID="${org_ids[$i]}"
            break 2
        fi
    done
    echo "Invalid selection. Please try again."
done

echo "-> Selected Organization: $opt ($SELECTED_ORG_ID)"

# 2. Check if project already exists, otherwise create it
echo ""
echo "===================================================="
echo " Checking for existing '$PROJECT_NAME' project..."
echo "===================================================="

PROJECT_ID=$(gcloud projects list \
    --filter="name='$PROJECT_NAME' AND lifecycleState='ACTIVE'" \
    --format="value(projectId)" | head -n 1)

if [ -n "$PROJECT_ID" ]; then
    echo "-> Found existing project: '$PROJECT_ID'"
else
    PROJECT_ID="csis-csa-resources-$(openssl rand -hex 4 2>/dev/null || echo "$RANDOM$RANDOM")"
    echo "-> No existing project found. Creating new project '$PROJECT_ID'..."
    gcloud projects create "$PROJECT_ID" \
        --name="$PROJECT_NAME" \
        --organization="$SELECTED_ORG_ID"
    echo "-> Project '$PROJECT_ID' created."
fi

PROJECT_NUM=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# 3. Enable required APIs
echo ""
echo "===================================================="
echo " Enabling required APIs on '$PROJECT_ID'..."
echo "===================================================="
gcloud services enable "${GCP_SERVICES[@]}" --project="$PROJECT_ID"
echo "-> APIs enabled."

# 4. Create the Service Account
echo ""
echo "===================================================="
echo " Creating Service Account..."
echo "===================================================="
SA_EMAIL="${SA_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    echo "-> Service account '$SA_EMAIL' already exists."
else
    gcloud iam service-accounts create "$SA_ACCOUNT_ID" \
        --project="$PROJECT_ID" \
        --display-name="$SA_ACCOUNT_ID"
    echo "-> Service account '$SA_EMAIL' created."
fi

# 5. Create the Workload Identity Pool
echo ""
echo "===================================================="
echo " Creating Workload Identity Pool..."
echo "===================================================="
if gcloud iam workload-identity-pools describe "$POOL_ID" \
    --project="$PROJECT_ID" --location="global" &>/dev/null; then
    echo "-> Workload identity pool '$POOL_ID' already exists."
else
    gcloud iam workload-identity-pools create "$POOL_ID" \
        --project="$PROJECT_ID" \
        --location="global" \
        --display-name="$POOL_ID"
    echo "-> Workload identity pool '$POOL_ID' created."
fi

# 6. Create the Workload Identity Pool Provider (X.509)
echo ""
echo "===================================================="
echo " Creating Workload Identity Pool Provider..."
echo "===================================================="

if [ ! -f "$TRUST_ANCHOR_FILE" ]; then
    echo "ERROR: '$TRUST_ANCHOR_FILE' not found. It is required to configure the X.509 provider."
    exit 1
fi

# Build the trust store config YAML expected by --trust-store-config-path
{
    echo "trustStore:"
    echo "  trustAnchors:"
    echo "  - pemCertificate: |"
    sed 's/^/      /' "$TRUST_ANCHOR_FILE"
} > "$TRUST_STORE_CONFIG_FILE"

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --project="$PROJECT_ID" --location="global" --workload-identity-pool="$POOL_ID" &>/dev/null; then
    echo "-> Provider '$PROVIDER_ID' already exists."
else
    gcloud iam workload-identity-pools providers create-x509 "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_ID" \
        --display-name="$PROVIDER_ID" \
        --trust-store-config-path="$TRUST_STORE_CONFIG_FILE" \
        --attribute-mapping="google.subject=assertion.subject.dn.cn"
    echo "-> Provider '$PROVIDER_ID' created."
fi

rm -f "$TRUST_STORE_CONFIG_FILE"

# Grant the Workload Identity Pool permission to impersonate the Service Account
echo ""
echo "===================================================="
echo " Granting Workload Identity impersonation rights..."
echo "===================================================="
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.subject/CSIS Collector" \
    >/dev/null
echo "-> Binding applied."

# 7. Create the Custom Role [Organization Level]
echo ""
echo "===================================================="
echo " Creating Custom Organization Role..."
echo "===================================================="

# Role IDs are derived deterministically from the project ID so re-running
# this script against the same project reuses the same role instead of
# creating duplicates.
ROLE_ID="csis_collector_role_$(echo "$PROJECT_ID" | tr -c 'a-zA-Z0-9' '_')"

if gcloud iam roles describe "$ROLE_ID" --organization="$SELECTED_ORG_ID" &>/dev/null; then
    echo "-> Role '$ROLE_ID' already exists. Updating permissions..."
    gcloud iam roles update "$ROLE_ID" \
        --organization="$SELECTED_ORG_ID" \
        --title="CSIS Collector role" \
        --stage="GA" \
        --permissions="$ROLE_PERMISSIONS" \
        >/dev/null
else
    gcloud iam roles create "$ROLE_ID" \
        --organization="$SELECTED_ORG_ID" \
        --title="CSIS Collector role" \
        --stage="GA" \
        --permissions="$ROLE_PERMISSIONS" \
        >/dev/null
    echo "-> Role '$ROLE_ID' created."
fi

# 8. Create the Role Binding [Organization Level]
echo ""
echo "===================================================="
echo " Binding Custom Role to Service Account..."
echo "===================================================="
gcloud organizations add-iam-policy-binding "$SELECTED_ORG_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="organizations/${SELECTED_ORG_ID}/roles/${ROLE_ID}" \
    >/dev/null
echo "-> Role bound to service account."

# Fetch the OAuth 2 Client ID (unique_id of the service account)
CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" --format="value(uniqueId)")

echo ""
echo "Deployment complete! Please save the following details:"
echo "----------------------------------------------------"
echo "Project ID:             $PROJECT_ID"
echo "Project Number:         $PROJECT_NUM"
echo "Service Account Email:  $SA_EMAIL"
echo "OAuth 2 Client ID:      $CLIENT_ID"
echo "----------------------------------------------------"
echo ""
echo "===================================================="
echo " Action Required: Google Workspaces Delegation"
echo "===================================================="
echo "To complete the setup, please perform the manual step (3.7):"
echo "1. Go to your Google Workspace Domain-Wide Delegation page."
echo "2. Add a new client with:"
echo "   - Client ID: $CLIENT_ID"
echo "   - OAuth Scopes:"
echo "     https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/admin.directory.group.readonly,https://www.googleapis.com/auth/admin.directory.domain.readonly,https://www.googleapis.com/auth/admin.reports.audit.readonly,https://www.googleapis.com/auth/admin.directory.user.security,https://www.googleapis.com/auth/cloud-identity.policies.readonly,https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly"
echo ""
echo "3. Once done, provide this Client ID ($CLIENT_ID) and your Workspace Super Admin email to the CSIS Cloud Security Assessment page to start the analysis."

