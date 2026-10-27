#!/bin/bash

# Delete only Chronos CSA resources in the selected organization.
set -e

PROJECT_ID_PREFIX="csis-csa-resources-"
ROLE_ID_PREFIX="csis_collector_role_"
SA_ACCOUNT_ID="csis-csa-collector"
PROJECT_NAME="CSIS-CSA-Resources"
ROLE_TITLE="CSIS Collector role"
DEPLOY_KEY_ID="170637f07a31b92389eeadeaaf0267ffc326fe62"
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


project_in_selected_org() {
    [ "$(gcloud projects get-ancestors "$1" --filter="type=organization" --format="value(id)")" = "$SELECTED_ORG_ID" ]
}

# Proof that a project holds a Chronos CSA deployment: the collector service account exists
# and carries the CSIS certificate key uploaded by deploy.sh.
project_has_collector_key() {
    gcloud iam service-accounts keys list \
        --iam-account="${SA_ACCOUNT_ID}@${1}.iam.gserviceaccount.com" --project="$1" \
        --format="value(name)" 2>/dev/null | sed 's|.*/||' | grep -qx "$DEPLOY_KEY_ID"
}

is_our_member() {
    local project
    for project in "${OUR_PROJECT_IDS[@]}"; do
        [ "$1" = "serviceAccount:${SA_ACCOUNT_ID}@${project}.iam.gserviceaccount.com" ] && return 0
    done
    return 1
}

# Dedicated projects: ID prefix AND display name AND organization AND collector key must all match.
PROJECT_OUTPUT=$(gcloud projects list \
    --filter="lifecycleState=ACTIVE AND projectId~'^${PROJECT_ID_PREFIX}' AND name='${PROJECT_NAME}'" \
    --format="value(projectId,name)" | sort)
PROJECTS=()
while IFS= read -r project; do
    [ -n "$project" ] || continue
    project_id=${project%%$'\t'*}
    if project_in_selected_org "$project_id" && project_has_collector_key "$project_id"; then
        PROJECTS+=("$project")
    fi
done <<< "$PROJECT_OUTPUT"

# A reused project is never deleted. Only its collector service account is removed, and only
# when .deploy_config names it and the account carries the CSIS certificate key.
REUSED_PROJECT=""
SA_EMAIL=""
if [ -n "$PROJECT_ID" ] && [[ "$PROJECT_ID" != ${PROJECT_ID_PREFIX}* ]]; then
    SA_EMAIL="${SA_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
    if project_in_selected_org "$PROJECT_ID" 2>/dev/null && project_has_collector_key "$PROJECT_ID"; then
        REUSED_PROJECT="$PROJECT_ID"
    fi
fi

# Only bindings of collector service accounts in these projects count as ours.
OUR_PROJECT_IDS=()
for project in "${PROJECTS[@]}"; do
    OUR_PROJECT_IDS+=("${project%%$'\t'*}")
done
[ -n "$REUSED_PROJECT" ] && OUR_PROJECT_IDS+=("$REUSED_PROJECT")

# Candidate roles: ID prefix AND the title deploy.sh gives them.
ROLE_OUTPUT=$(gcloud iam roles list --organization="$SELECTED_ORG_ID" \
    --filter="name~'/roles/${ROLE_ID_PREFIX}' AND title='${ROLE_TITLE}'" \
    --format="value(name)" | sed 's|.*/||' | sort)
mapfile -t CANDIDATE_ROLE_IDS < <(printf '%s' "$ROLE_OUTPUT")

BINDING_ROLES=()
BINDING_MEMBERS=()
declare -A FOREIGN_ROLES=()
for role_id in "${CANDIDATE_ROLE_IDS[@]}"; do
    [ -n "$role_id" ] || continue
    role="organizations/${SELECTED_ORG_ID}/roles/${role_id}"
    MEMBER_OUTPUT=$(gcloud organizations get-iam-policy "$SELECTED_ORG_ID" \
        --flatten="bindings[].members" --filter="bindings.role=$role" \
        --format="value(bindings.members)" | sort -u)
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        if is_our_member "$member"; then
            BINDING_ROLES+=("$role")
            BINDING_MEMBERS+=("$member")
        else
            FOREIGN_ROLES["$role_id"]=1
        fi
    done <<< "$MEMBER_OUTPUT"
done

# Project-level bindings (from "Selected projects" access). Dedicated projects are skipped
# because deleting them removes their policies.
PBIND_PROJECTS=()
PBIND_ROLES=()
PBIND_MEMBERS=()
if [ ${#CANDIDATE_ROLE_IDS[@]} -gt 0 ] && [ -n "${CANDIDATE_ROLE_IDS[0]}" ]; then
    ALL_PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format="value(projectId)")
    while IFS= read -r access_project; do
        [ -n "$access_project" ] || continue
        is_dedicated=false
        for project in "${PROJECTS[@]}"; do
            [ "${project%%$'\t'*}" = "$access_project" ] && is_dedicated=true
        done
        [ "$is_dedicated" = true ] && continue
        for role_id in "${CANDIDATE_ROLE_IDS[@]}"; do
            role="organizations/${SELECTED_ORG_ID}/roles/${role_id}"
            MEMBER_OUTPUT=$(gcloud projects get-iam-policy "$access_project" \
                --flatten="bindings[].members" --filter="bindings.role=$role" \
                --format="value(bindings.members)" 2>/dev/null | sort -u || true)
            while IFS= read -r member; do
                [ -n "$member" ] || continue
                if is_our_member "$member"; then
                    PBIND_PROJECTS+=("$access_project")
                    PBIND_ROLES+=("$role")
                    PBIND_MEMBERS+=("$member")
                else
                    FOREIGN_ROLES["$role_id"]=1
                fi
            done <<< "$MEMBER_OUTPUT"
        done
    done <<< "$ALL_PROJECT_IDS"
fi

# A role is deleted only when nothing but our collector service accounts is bound to it.
ROLE_IDS=()
KEPT_ROLE_IDS=()
for role_id in "${CANDIDATE_ROLE_IDS[@]}"; do
    [ -n "$role_id" ] || continue
    if [ -n "${FOREIGN_ROLES[$role_id]}" ]; then
        KEPT_ROLE_IDS+=("$role_id")
    else
        ROLE_IDS+=("$role_id")
    fi
done

if [ ${#PROJECTS[@]} -eq 0 ] && [ ${#CANDIDATE_ROLE_IDS[@]} -eq 0 ] && [ -z "$REUSED_PROJECT" ]; then
    echo "No Chronos CSA projects or organization roles were found in '$SELECTED_ORG_NAME' ($SELECTED_ORG_ID)."
    echo "Google Workspace Domain-Wide Delegation is not checked. Remove the collector's client entry manually if it still exists:"
    echo "https://admin.google.com/ac/owl/domainwidedelegation"
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

if [ ${#KEPT_ROLE_IDS[@]} -gt 0 ]; then
    echo "Organization roles KEPT (other principals are bound to them):"
    for role_id in "${KEPT_ROLE_IDS[@]}"; do
        echo "  - $role_id"
    done
fi

if [ ${#BINDING_MEMBERS[@]} -gt 0 ]; then
    echo "Organization role bindings scheduled for removal:"
    for i in "${!BINDING_MEMBERS[@]}"; do
        echo "  - ${BINDING_MEMBERS[$i]} -> ${BINDING_ROLES[$i]}"
    done
fi

if [ ${#PBIND_MEMBERS[@]} -gt 0 ]; then
    echo "Project role bindings scheduled for removal:"
    for i in "${!PBIND_MEMBERS[@]}"; do
        echo "  - ${PBIND_PROJECTS[$i]}: ${PBIND_MEMBERS[$i]} -> ${PBIND_ROLES[$i]}"
    done
fi

if [ -n "$REUSED_PROJECT" ]; then
    echo "Reused project (kept): $REUSED_PROJECT"
    echo "  - only service account $SA_EMAIL and its keys will be deleted"
    echo "  - its project policy and enabled APIs are left unchanged"
fi

echo ""
echo "The script will remove bindings for these roles, delete the roles, then delete the projects."
echo "Deleting a dedicated project also removes its service account, uploaded certificate key, and project policy override."
echo "Google Workspace Domain-Wide Delegation must be removed manually; record the collector's client ID before continuing."
echo "https://admin.google.com/ac/owl/domainwidedelegation"
read -r -p "Type 'yes' to permanently start this cleanup: " CLEANUP_CONFIRM
if [[ "$CLEANUP_CONFIRM" != "yes" ]]; then
    echo "Cleanup cancelled. No resources were changed."
    exit 0
fi

for i in "${!BINDING_MEMBERS[@]}"; do
    echo "-> Removing binding: ${BINDING_MEMBERS[$i]} -> ${BINDING_ROLES[$i]}"
    gcloud organizations remove-iam-policy-binding "$SELECTED_ORG_ID" \
        --member="${BINDING_MEMBERS[$i]}" --role="${BINDING_ROLES[$i]}" --quiet \
        >/dev/null
done

for i in "${!PBIND_MEMBERS[@]}"; do
    echo "-> Removing binding on project '${PBIND_PROJECTS[$i]}': ${PBIND_MEMBERS[$i]} -> ${PBIND_ROLES[$i]}"
    gcloud projects remove-iam-policy-binding "${PBIND_PROJECTS[$i]}" \
        --member="${PBIND_MEMBERS[$i]}" --role="${PBIND_ROLES[$i]}" --quiet \
        >/dev/null
done

for role_id in "${ROLE_IDS[@]}"; do
    echo "-> Deleting organization role '$role_id'..."
    gcloud iam roles delete "$role_id" --organization="$SELECTED_ORG_ID" --quiet \
        >/dev/null
done

if [ -n "$REUSED_PROJECT" ]; then
    echo "-> Deleting service account '$SA_EMAIL' in reused project '$REUSED_PROJECT'..."
    gcloud iam service-accounts delete "$SA_EMAIL" --project="$REUSED_PROJECT" --quiet >/dev/null
fi

for project in "${PROJECTS[@]}"; do
    project_id=${project%%$'\t'*}
    echo "-> Deleting project '$project_id'..."
    gcloud projects delete "$project_id" --quiet >/dev/null
done

rm -f "$DEPLOY_CONFIG_FILE"
echo "Cleanup complete. Project deletion is scheduled by Google Cloud and may be recoverable only during its retention period."
echo "Remove the collector's client entry from Google Workspace Domain-Wide Delegation if it was configured."
