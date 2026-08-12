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

## What Gets Created

- **Project**: `CSIS-CSA-Resources` (or similar unique identifier)
- **Service Account**: `csis-csa-collector@<project-id>.iam.gserviceaccount.com`
- **Workload Identity Pool**: `csis-identity-pool` (X.509 provider)
- **Custom Role**: Organization-level role with audit permissions including:
  - Essential Contacts listing
  - IAM policies and roles inspection
  - Cloud Logging access
  - Cloud Asset inventory
  - Service usage monitoring
  - Storage bucket auditing
  - And more...

## Cleanup

Simply delete the `CSIS-CSA-Resources` project in the Google Cloud Console. No Terraform state files or manual cleanup needed.

## Security Notes

- Service account permissions are minimal and scoped to audit-only operations
- X.509 workload identity provides secure, certificate-based authentication
- No credentials are stored locally; authentication flows through GCP's workload identity system

## Support

For issues or questions, refer to the CSIS Cloud Security Assessment documentation.
