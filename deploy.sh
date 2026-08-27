#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

wait_for() {
    local description="$1"
    local attempts="$2"
    local delay="$3"
    shift 3

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if "$@"; then
            echo "-> $description is ready."
            return 0
        fi

        if [ "$attempt" -lt "$attempts" ]; then
            echo "-> Waiting for $description ($attempt/$attempts)..."
            sleep "$delay"
        fi
    done

    echo "ERROR: Timed out waiting for $description."
    return 1
}

check_organization_access() {
    gcloud organizations describe "$SELECTED_ORG_ID" >/dev/null
    gcloud organizations get-iam-policy "$SELECTED_ORG_ID" >/dev/null
    gcloud iam roles list --organization="$SELECTED_ORG_ID" --limit=1 >/dev/null
}

check_project_access() {
    gcloud projects describe "$PROJECT_ID" >/dev/null
    gcloud services list --enabled --project="$PROJECT_ID" --limit=1 >/dev/null
}

project_is_active() {
    [ "$(gcloud projects describe "$PROJECT_ID" --format="value(lifecycleState)" 2>/dev/null)" = "ACTIVE" ]
}

api_is_enabled() {
    gcloud services list --enabled --project="$PROJECT_ID" \
        --filter="config.name=$1" --format="value(config.name)" 2>/dev/null | grep -qx "$1"
}

service_account_exists() {
    gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1
}

workload_identity_pool_exists() {
    gcloud iam workload-identity-pools describe "$POOL_ID" \
        --project="$PROJECT_ID" --location="global" >/dev/null 2>&1
}

workload_identity_provider_exists() {
    gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
        --project="$PROJECT_ID" --location="global" \
        --workload-identity-pool="$POOL_ID" >/dev/null 2>&1
}

# Because everything is created inside a single dedicated project
# ("CSIS-CSA-Resources"), the whole deployment can be torn down at any time
# simply by deleting that project.

PROJECT_NAME="CSIS-CSA-Resources"
SA_ACCOUNT_ID="csis-csa-collector"
JWT_SIGNER_ROLE_ID="csis_service_account_jwt_signer"
POOL_ID="csis-identity-pool"
PROVIDER_ID="csis-cert-provider"
TRUST_ANCHOR_FILE="trust_anchor.pem"
TRUST_STORE_CONFIG_FILE=".trust_store_config.generated.yaml"
DEPLOY_CONFIG_FILE=".deploy_config"

GCP_SERVICES=(
    "cloudresourcemanager.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "logging.googleapis.com"
    "cloudasset.googleapis.com"
    "serviceusage.googleapis.com"
    "essentialcontacts.googleapis.com"
    "securitycenter.googleapis.com"
    "storage.googleapis.com"
    "run.googleapis.com"
    "admin.googleapis.com"
    "cloudidentity.googleapis.com"
    "apikeys.googleapis.com"
    "orgpolicy.googleapis.com"
)

ROLE_PERMISSIONS="apikeys.keys.list,cloudasset.assets.searchAllIamPolicies,cloudasset.assets.searchAllResources,essentialcontacts.contacts.list,iam.accesspolicies.list,iam.policybindings.list,iam.roles.list,iam.serviceAccountKeys.list,iam.serviceAccounts.list,logging.logEntries.list,logging.logs.list,orgpolicy.constraints.list,orgpolicy.customConstraints.list,orgpolicy.policies.list,resourcemanager.folders.get,resourcemanager.organizations.get,resourcemanager.projects.get,run.jobs.list,run.services.list,run.workerpools.list,securitycenter.findings.list,serviceusage.services.list,storage.buckets.list,storage.hmacKeys.list"
SCOPES="https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/admin.directory.domain.readonly,https://www.googleapis.com/auth/admin.directory.group.member.readonly,https://www.googleapis.com/auth/admin.directory.group.readonly,https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly,https://www.googleapis.com/auth/admin.directory.user.readonly,https://www.googleapis.com/auth/admin.directory.user.security,https://www.googleapis.com/auth/admin.reports.audit.readonly,https://www.googleapis.com/auth/apps.security,https://www.googleapis.com/auth/cloud-identity.policies.readonly"

# Load saved configuration if it exists
if [ -f "$DEPLOY_CONFIG_FILE" ]; then
    echo "Loading configuration from $DEPLOY_CONFIG_FILE..."
    source "$DEPLOY_CONFIG_FILE"
fi

echo "===================================================="
echo " Checking GCP Authentication..."
echo "===================================================="
for command in gcloud curl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command '$command' is not installed or is not on PATH."
        exit 1
    fi
done

if [ ! -f "$TRUST_ANCHOR_FILE" ]; then
    echo "ERROR: '$TRUST_ANCHOR_FILE' not found. It is required to configure the X.509 provider."
    exit 1
fi

# Ensure the user is authenticated
gcloud auth application-default print-access-token &>/dev/null || {
    echo "You are not authenticated. Running 'gcloud auth application-default login'..."
    gcloud auth application-default login
}
gcloud auth print-access-token &>/dev/null || {
    echo "You are not authenticated for gcloud commands. Running 'gcloud auth login'..."
    gcloud auth login
}
DEPLOYER_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
if [ -z "$DEPLOYER_ACCOUNT" ] || [ "$DEPLOYER_ACCOUNT" = "(unset)" ]; then
    echo "ERROR: No active gcloud account is configured. Run 'gcloud auth login' and try again."
    exit 1
fi
echo "-> Deploying as: '$DEPLOYER_ACCOUNT'"

# 1. Get Collector ID from argument or environment
echo ""
echo "===================================================="
echo " Collector Configuration"
echo "===================================================="
if [ -z "$COLLECTOR_ID" ]; then
    if [ -z "$1" ]; then
        echo "ERROR: Collector ID must be provided as an argument or loaded from config."
        echo "Usage: bash deploy.sh <COLLECTOR_ID>"
        echo "Example: bash deploy.sh 20XXXXXXXXXXXXXX"
        exit 1
    fi
    COLLECTOR_ID="$1"
fi
echo "-> Collector ID set to: '$COLLECTOR_ID'"

# 2. Get Super Admin Email
echo ""
echo "===================================================="
echo " Google Workspace Super Admin"
echo "===================================================="
echo "A list of admins can be found in the Google Admin Console under 'Directory' -> 'Users' -> 'Admin roles'."
echo "https://admin.google.com/ac/roles/75874321289921097/admins?journey=45"
if [ -z "$SUPER_ADMIN_EMAIL" ]; then
    read -p "Enter the Google Workspace Super Admin email address: " SUPER_ADMIN_EMAIL
    if [ -z "$SUPER_ADMIN_EMAIL" ]; then
        echo "ERROR: Super Admin email cannot be empty."
        exit 1
    fi

    echo "-> Super Admin email set to: '$SUPER_ADMIN_EMAIL'"
else
    echo "Using SUPER_ADMIN_EMAIL from environment: '$SUPER_ADMIN_EMAIL'"
fi

if [ -z "$SELECTED_ORG_ID" ]; then
    # 3. Select Organization
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
else
    echo "Using SELECTED_ORG_ID from environment: '$SELECTED_ORG_ID'"
fi

SELECTED_ORG_NAME=$(gcloud organizations describe "$SELECTED_ORG_ID" --format="value(displayName)")
if [ -z "$SELECTED_ORG_NAME" ]; then
    echo "ERROR: Could not determine the display name for organization '$SELECTED_ORG_ID'."
    exit 1
fi
echo "-> Organization name: '$SELECTED_ORG_NAME'"

# 4. Validate organization permissions before making any changes
echo ""
echo "===================================================="
echo " Checking Organization Access..."
echo "===================================================="
check_organization_access
echo "-> Organization can be read and its IAM policy and custom roles can be listed."
echo "-> The gcloud CLI cannot preflight individual create/update IAM permissions; commands will fail before dependent steps if access is missing."

# Require explicit confirmation before the first mutation.
echo ""
echo "===================================================="
echo " Deployment Summary"
echo "===================================================="
echo "Deployer:             $DEPLOYER_ACCOUNT"
echo "Organization:         $SELECTED_ORG_NAME ($SELECTED_ORG_ID)"
echo "Project name:         $PROJECT_NAME"
echo "Service account:      ${SA_ACCOUNT_ID}@<new-project>.iam.gserviceaccount.com"
echo "Workload identity:    $POOL_ID / $PROVIDER_ID"
echo "Organization role:    CSIS Collector audit role"
echo "Project role:         $JWT_SIGNER_ROLE_ID (iam.serviceAccounts.signJwt)"
echo "IAM bindings:         Workload Identity User and service-account self-signing"
echo ""
read -r -p "Type 'yes' to create or update these resources: " DEPLOY_CONFIRM
if [[ "$DEPLOY_CONFIRM" != "yes" ]]; then
    echo "Deployment cancelled. No resources were created or changed."
    exit 0
fi

# Save configuration only after deployment has been explicitly approved.
cat > "$DEPLOY_CONFIG_FILE" << EOF
export COLLECTOR_ID="$COLLECTOR_ID"
export SUPER_ADMIN_EMAIL="$SUPER_ADMIN_EMAIL"
export SELECTED_ORG_ID="$SELECTED_ORG_ID"
EOF
echo "Configuration saved to $DEPLOY_CONFIG_FILE for resuming deployments"

# 5. Check if project already exists, otherwise create it
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

wait_for "project '$PROJECT_ID' to become active" 30 5 \
    project_is_active
PROJECT_NUM=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# Project-scoped permissions cannot be evaluated until the project exists.
echo ""
echo "===================================================="
echo " Checking Project Access..."
echo "===================================================="
wait_for "project access to propagate" 12 5 check_project_access
echo "-> Project can be read and its enabled services can be listed."

# 6. Enable required APIs
echo ""
echo "===================================================="
echo " Enabling required APIs on '$PROJECT_ID'..."
echo "===================================================="
gcloud services enable "${GCP_SERVICES[@]}" --project="$PROJECT_ID"
for service in "${GCP_SERVICES[@]}"; do
    wait_for "API '$service'" 24 5 api_is_enabled "$service"
done
echo "-> APIs enabled."

# 7. Create the Service Account
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
wait_for "service account '$SA_EMAIL'" 12 5 \
    service_account_exists

# 8. Create the Workload Identity Pool
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
wait_for "workload identity pool '$POOL_ID'" 12 5 \
    workload_identity_pool_exists

# 9. Create the Workload Identity Pool Provider (X.509)
echo ""
echo "===================================================="
echo " Creating Workload Identity Pool Provider..."
echo "===================================================="

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
wait_for "workload identity provider '$PROVIDER_ID'" 12 5 \
    workload_identity_provider_exists

rm -f "$TRUST_STORE_CONFIG_FILE"

# Grant the Workload Identity Pool permission to impersonate the Service Account
echo ""
echo "===================================================="
echo " Granting Workload Identity impersonation rights..."
echo "===================================================="
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.subject/example" \
    >/dev/null
echo "-> Binding applied."

# 9. Create the Custom Role [Organization Level]
echo ""
echo "===================================================="
echo " Creating Custom Organization Role..."
echo "===================================================="

# Use the project suffix for the role ID (deterministic)
PROJECT_SUFFIX=$(echo "$PROJECT_ID" | sed 's/.*-//')
ROLE_ID="csis_collector_role_$PROJECT_SUFFIX"

# Check if a matching role already exists with this exact ID
if gcloud iam roles describe "$ROLE_ID" --organization="$SELECTED_ORG_ID" &>/dev/null; then
    echo "-> Role '$ROLE_ID' already exists. Updating permissions..."
    gcloud iam roles update "$ROLE_ID" \
        --quiet \
        --organization="$SELECTED_ORG_ID" \
        --title="CSIS Collector role" \
        --stage="GA" \
        --permissions="$ROLE_PERMISSIONS"
    echo "-> Role '$ROLE_ID' updated."
else
    echo "-> No existing role found. Creating new role..."
    gcloud iam roles create "$ROLE_ID" \
        --quiet \
        --organization="$SELECTED_ORG_ID" \
        --title="CSIS Collector role" \
        --stage="GA" \
        --permissions="$ROLE_PERMISSIONS"
    echo "-> Role '$ROLE_ID' created."
fi

# 10. Create the Role Binding [Organization Level]
echo ""
echo "===================================================="
echo " Binding Custom Role to Service Account..."
echo "===================================================="

gcloud organizations add-iam-policy-binding "$SELECTED_ORG_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="organizations/${SELECTED_ORG_ID}/roles/${ROLE_ID}" \
    >/dev/null
echo "-> Role bound to service account."

# The collector signs its domain-wide delegation assertion as itself. Keep this
# permission on the individual service account rather than the whole project.
echo ""
echo "===================================================="
echo " Creating Service Account JWT Signer Role..."
echo "===================================================="

if gcloud iam roles describe "$JWT_SIGNER_ROLE_ID" --project="$PROJECT_ID" &>/dev/null; then
    echo "-> Role '$JWT_SIGNER_ROLE_ID' already exists. Updating permissions..."
    gcloud iam roles update "$JWT_SIGNER_ROLE_ID" \
        --quiet \
        --project="$PROJECT_ID" \
        --title="CSIS Service Account JWT Signer" \
        --stage="GA" \
        --permissions="iam.serviceAccounts.signJwt"
    echo "-> Role '$JWT_SIGNER_ROLE_ID' updated."
else
    gcloud iam roles create "$JWT_SIGNER_ROLE_ID" \
        --quiet \
        --project="$PROJECT_ID" \
        --title="CSIS Service Account JWT Signer" \
        --stage="GA" \
        --permissions="iam.serviceAccounts.signJwt"
    echo "-> Role '$JWT_SIGNER_ROLE_ID' created."
fi

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="projects/${PROJECT_ID}/roles/${JWT_SIGNER_ROLE_ID}" \
    >/dev/null
echo "-> JWT signer role bound to service account."

# Fetch the OAuth 2 Client ID (unique_id of the service account)
CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" --format="value(uniqueId)")

echo "===================================================="
echo " Action Required: Google Workspaces Delegation"
echo "===================================================="
echo "To complete the setup, please perform the manual step:"
echo "1. Go to your Google Workspace Domain-Wide Delegation page: https://admin.google.com/ac/owl/domainwidedelegation"
echo "2. Add a new client with:"
echo "   - Client ID: $CLIENT_ID"
echo "   - OAuth Scopes:"
echo "     $SCOPES"
echo ""
echo "===================================================="
echo ""

read -p "Have you completed the Domain-Wide Delegation setup? Type 'yes' or 'no': " DWD_CONFIRM

if [[ "$DWD_CONFIRM" != "yes" && "$DWD_CONFIRM" != "no" ]]; then
    echo "ERROR: Please enter 'yes' or 'no'."
    exit 1
fi

echo ""

if [[ "$DWD_CONFIRM" == "yes" ]]; then
    PAYLOAD="{
      \"projectNumber\": \"$PROJECT_NUM\",
      \"OrgName\": \"$SELECTED_ORG_NAME\",
      \"superAdminEmail\": \"$SUPER_ADMIN_EMAIL\",
      \"serviceAccountEmail\": \"$SA_EMAIL\"
    }"
else
    PAYLOAD="{
      \"projectNumber\": \"$PROJECT_NUM\",
      \"OrgName\": \"$SELECTED_ORG_NAME\",
      \"serviceAccountEmail\": \"$SA_EMAIL\"
    }"
fi

curl -X POST "https://csa.cs-staging.csis.com/$COLLECTOR_ID/Google/api/submit/" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"

echo ""
echo "Deployment complete! You can now close this terminal."
