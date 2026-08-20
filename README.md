# Chronos CSA - Google Cloud Security Assessment Tool

A deployment toolkit for the Chronos Cloud Security Assessment (CSA) tool that integrates with Google Cloud Platform to audit and assess security posture across your organization.

## Overview

This tool automates the deployment of infrastructure necessary to run the Chronos CSA assessment against a Google Cloud organization. It sets up:

- **GCP Project**: A dedicated project (`CSIS-CSA-Resources`) for all CSA resources
- **Service Account**: A service account with minimal required permissions for security assessment
- **Workload Identity Pool**: X.509-based workload identity for secure authentication
- **Custom IAM Role**: Organization-level role with only necessary audit permissions
- **Domain-Wide Delegation**: Integration with Google Workspace for data collection

## Prerequisites

- `gcloud` CLI installed and configured
- Authentication to GCP via `gcloud auth application-default login`
- Required IAM permissions:
  - `roles/resourcemanager.organizationViewer` to select your organization
  - `roles/resourcemanager.projectCreator` to create the CSA project
  - `roles/iam.securityAdmin` to create service accounts and roles
- Google Workspace Super Admin access (for final delegation step)
- X.509 trust anchor certificate (`trust_anchor.pem`)

## Quick Start

1. **Run the deployment script**:
   ```bash
   bash deploy.sh
   ```

2. **Select your organization** when prompted

3. **Complete the Google Workspace setup** (manual step):
   - Navigate to your Google Workspace Domain-Wide Delegation settings
   - Add the new OAuth client with the provided Client ID
   - Grant the specified OAuth scopes
   - Provide the Client ID and Super Admin email to the CSIS CSA platform

## Deployment Safeguards

Before making changes, the script uses only the `gcloud` CLI to verify the active account can read the organization, its IAM policy, and custom roles, then displays a summary of the resources it will create or update. You must type `yes` to continue; any other response exits without creating resources or saving deployment configuration.

After the project is available, the script verifies it can be read and its enabled services listed before proceeding. The `gcloud` CLI does not provide an organization/project `testIamPermissions` command, so it cannot preflight individual create or update permissions. Those commands fail before dependent steps if access is missing. The script waits for the project, enabled APIs, service account, and workload identity resources to be ready before using them. IAM permission propagation can still take a short time, so these checks use bounded retries and report a clear timeout if Google Cloud does not make a resource available in time.

## What Gets Created

- **Project**: `CSIS-CSA-Resources` (or similar unique identifier)
- **Service Account**: `csis-csa-collector@<project-id>.iam.gserviceaccount.com`
- **Workload Identity Pool**: `csis-identity-pool` (X.509 provider)
- **Custom Role**: Organization-level role with audit permissions including:
  - Essential Contacts listing
  - IAM policies and roles inspection
  - Cloud Logging access
  - Cloud Asset inventory
  - Organization Policies, constraints, and custom constraints
  - Service usage monitoring
  - Storage bucket auditing
  - And more...

## Cleanup

Run the cleanup script to find and remove Chronos CSA resources in the selected organization:

```bash
bash cleanup.sh
```

The script discovers only projects with IDs beginning `csis-csa-resources-` and organization custom roles beginning `csis_collector_role_` in the selected organization. It lists all matching resources and requires you to type `yes` before removing role bindings, deleting the roles, and deleting the projects. Google Cloud schedules deleted projects for deletion and may allow recovery only during its retention period.

## Security Notes

- Service account permissions are minimal and scoped to audit-only operations
- X.509 workload identity provides secure, certificate-based authentication
- No credentials are stored locally; authentication flows through GCP's workload identity system

## Support

For issues or questions, refer to the CSIS Cloud Security Assessment documentation.
