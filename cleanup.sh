#!/bin/bash

# Delete only Chronos CSA resources in the selected organization.
set -e

PROJECT_ID_PREFIX="csis-csa-resources-"
ROLE_ID_PREFIX="csis_collector_role_"
DEPLOY_CONFIG_FILE=".deploy_config"

if [ -f "$DEPLOY_CONFIG_FILE" ]; then
    echo "Loading organization configuration from $DEPLOY_CONFIG_FILE..."
    source "$DEPLOY_CONFIG_FILE"
fi

echo "===================================================="
echo " Checking GCP Authentication..."
echo "===================================================="
if ! command -v gcloud >/dev/null 2>&1; then
    echo "ERROR: Required command 'gcloud' is not installed or is not on PATH."
    exit 1
fi

gcloud auth print-access-token >/dev/null 2>&1 || {
    echo "You are not authenticated for gcloud commands. Running 'gcloud auth login'..."
    gcloud auth login
}

DEPLOYER_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
if [ -z "$DEPLOYER_ACCOUNT" ] || [ "$DEPLOYER_ACCOUNT" = "(unset)" ]; then
    echo "ERROR: No active gcloud account is configured. Run 'gcloud auth login' and try again."
    exit 1
fi
echo "-> Cleaning up as: '$DEPLOYER_ACCOUNT'"

if [ -z "$SELECTED_ORG_ID" ]; then
    echo ""
    echo "===================================================="
    echo " Fetching available Organizations..."
    echo "===================================================="

    orgs=()
    org_ids=()
    while read -r name id; do
        if [[ -n "$name" && -n "$id" ]]; then
            orgs+=("$name")
            org_ids+=("$id")
        fi
    done < <(gcloud organizations list --format="value(displayName,ID)")

    if [ ${#orgs[@]} -eq 0 ]; then
        echo "ERROR: No organizations found. Ensure you have organization viewing permissions."
        exit 1
    fi

    echo "Select the organization to clean up:"
    select opt in "${orgs[@]}"; do
        for i in "${!orgs[@]}"; do
            if [[ "${orgs[$i]}" == "$opt" ]]; then
                SELECTED_ORG_ID="${org_ids[$i]}"
                break 2
            fi
        done
        echo "Invalid selection. Please try again."
    done
else
    echo "Using SELECTED_ORG_ID from configuration: '$SELECTED_ORG_ID'"
fi

SELECTED_ORG_NAME=$(gcloud organizations describe "$SELECTED_ORG_ID" --format="value(displayName)")
if [ -z "$SELECTED_ORG_NAME" ]; then
    echo "ERROR: Could not determine the display name for organization '$SELECTED_ORG_ID'."
    exit 1
fi

# Restrict project discovery to the selected organization so resources elsewhere are untouched.
mapfile -t PROJECTS < <(gcloud projects list \
    --filter="parent.id=$SELECTED_ORG_ID AND parent.type=organization AND projectId~'^${PROJECT_ID_PREFIX}'" \
    --format="value(projectId,name)" | sort)
mapfile -t ROLE_IDS < <(gcloud iam roles list --organization="$SELECTED_ORG_ID" \
    --format="value(name)" | grep "/roles/${ROLE_ID_PREFIX}" | sed 's|.*/||' | sort || true)

BINDING_ROLES=()
BINDING_MEMBERS=()
for role_id in "${ROLE_IDS[@]}"; do
    role="organizations/${SELECTED_ORG_ID}/roles/${role_id}"
    mapfile -t MEMBERS < <(gcloud organizations get-iam-policy "$SELECTED_ORG_ID" \
        --flatten="bindings[].members" --filter="bindings.role=$role" \
        --format="value(bindings.members)" | sort -u)

    for member in "${MEMBERS[@]}"; do
        if [ -n "$member" ]; then
            BINDING_ROLES+=("$role")
            BINDING_MEMBERS+=("$member")
        fi
    done
done

if [ ${#PROJECTS[@]} -eq 0 ] && [ ${#ROLE_IDS[@]} -eq 0 ]; then
    echo "No Chronos CSA projects or organization roles were found in '$SELECTED_ORG_NAME' ($SELECTED_ORG_ID)."
    exit 0
fi

echo ""
echo "===================================================="
echo " Cleanup Summary"
echo "===================================================="
echo "Organization: $SELECTED_ORG_NAME ($SELECTED_ORG_ID)"

if [ ${#PROJECTS[@]} -gt 0 ]; then
    echo "Projects scheduled for deletion:"
    for project in "${PROJECTS[@]}"; do
        echo "  - $project"
    done
fi

if [ ${#ROLE_IDS[@]} -gt 0 ]; then
    echo "Organization roles scheduled for deletion:"
    for role_id in "${ROLE_IDS[@]}"; do
        echo "  - $role_id"
    done
fi

if [ ${#BINDING_MEMBERS[@]} -gt 0 ]; then
    echo "Organization role bindings scheduled for removal:"
    for i in "${!BINDING_MEMBERS[@]}"; do
        echo "  - ${BINDING_MEMBERS[$i]} -> ${BINDING_ROLES[$i]}"
    done
fi

echo ""
echo "The script will remove bindings for these roles, delete the roles, then delete the projects."
read -r -p "Type 'yes' to permanently start this cleanup: " CLEANUP_CONFIRM
if [[ "$CLEANUP_CONFIRM" != "yes" ]]; then
    echo "Cleanup cancelled. No resources were changed."
    exit 0
fi

if [ ${#ROLE_IDS[@]} -gt 0 ]; then
    for i in "${!BINDING_MEMBERS[@]}"; do
        echo "-> Removing binding: ${BINDING_MEMBERS[$i]} -> ${BINDING_ROLES[$i]}"
        gcloud organizations remove-iam-policy-binding "$SELECTED_ORG_ID" \
            --member="${BINDING_MEMBERS[$i]}" --role="${BINDING_ROLES[$i]}" --quiet
    done

    for role_id in "${ROLE_IDS[@]}"; do
        role="organizations/${SELECTED_ORG_ID}/roles/${role_id}"
        echo "-> Deleting organization role '$role_id'..."
        gcloud iam roles delete "$role_id" --organization="$SELECTED_ORG_ID" --quiet
    done
fi

for project in "${PROJECTS[@]}"; do
    project_id=${project%%$'\t'*}
    echo "-> Deleting project '$project_id'..."
    gcloud projects delete "$project_id" --quiet
done

rm -f "$DEPLOY_CONFIG_FILE"
echo "Cleanup complete. Project deletion is scheduled by Google Cloud and may be recoverable only during its retention period."
