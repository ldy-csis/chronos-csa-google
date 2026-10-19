# Chronos CSA - Google Cloud Security Assessment Tool

A deployment toolkit for the Chronos Cloud Security Assessment (CSA) tool that configures access to a Google Cloud organization and, optionally, Google Workspace.

## Overview

`deploy.sh` creates or reuses a dedicated Google Cloud project, enables the required APIs, creates a collector service account, and uploads the CSIS public certificate as a service account key. It creates or updates an organization-level custom audit role and binds it to the service account.

Authentication uses the uploaded certificate key, not a workload identity pool or provider. The script does not create a JWT signer role.

## Prerequisites

- Bash 4 or later, Google Cloud CLI (`gcloud`), `curl`, and standard shell utilities. Google Cloud Shell is a suitable environment.
- Run the scripts from this repository's directory with the supplied `deploy-certificate.pem` present. No private key is generated or uploaded by the scripts.
- A collector ID from the CSIS CSA platform.
- A Google Cloud account with permissions to:
  - List and read organizations, read the selected organization's IAM policy, and list its custom roles.
  - Create projects in the selected organization, or manage an existing CSA project.
  - Enable APIs, create service accounts, list service account keys, and upload service account public keys.
  - Disable enforcement of `constraints/iam.disableServiceAccountKeyUpload` on the CSA project when the expected key is absent.
  - Create or update organization custom roles and add organization IAM policy bindings.
- A Google Workspace Super Admin email address. Super Admin access is required to configure Domain-Wide Delegation if Workspace collection is wanted.

The script checks both application-default credentials and the active `gcloud` account, prompting for `gcloud auth application-default login` and `gcloud auth login` when needed.

## Quick Start

1. **Run the deployment script with your collector ID**:
   ```bash
   bash deploy.sh <COLLECTOR_ID>
   ```

2. **Provide the Super Admin email and select your organization** when prompted. Review the deployment summary and type `yes` to create or update resources.

3. **Configure Google Workspace Domain-Wide Delegation** if Workspace collection is wanted:
   - Open [Domain-Wide Delegation](https://admin.google.com/ac/owl/domainwidedelegation).
   - Add a client using the service account client ID and the exact comma-separated OAuth scopes printed by the script.
   - Return to the script and answer `yes` once configured, or `no` to finish without Workspace delegation.

The script submits the collector ID, project number, organization name, service account email, and uploaded key ID to `https://csa.cs-staging.csis.com/<COLLECTOR_ID>/Google/api/submit/`. The Super Admin email is included only when delegation is confirmed.

After deployment is approved, `.deploy_config` saves `COLLECTOR_ID`, `SUPER_ADMIN_EMAIL`, and `SELECTED_ORG_ID` in the current directory. Later runs load this file, and its values take precedence over environment variables and the collector ID argument. Edit or remove it before deploying for a different collector or organization. Do not commit this local configuration.

## Deployment Safeguards

Before changing cloud resources, the script checks that the active account can read the organization, its IAM policy, and custom roles. It displays a deployment summary and requires `yes` to proceed; any other response exits without creating resources or saving deployment configuration. Authentication may still update local credentials before this confirmation.

After the project is available, the script checks project access and waits with bounded retries for the project, enabled APIs, and service account to become available. These checks do not preflight every required create or update permission; later commands can still fail if access is missing.

Before uploading, the script lists the service account keys and looks for the expected key ID configured in `DEPLOY_KEY_ID`. An existing enabled key is reused without changing the upload policy or uploading again. If that key is disabled, deployment stops with an error; unrelated keys do not prevent upload.

The script reuses the first active project it finds with display name `CSIS-CSA-Resources`. This lookup is not scoped to the selected organization, so verify that the deploying account does not have a same-named CSA project in another organization.

## What Gets Created or Updated

| Resource | Configuration |
|----------|---------------|
| Project | Display name `CSIS-CSA-Resources`; new project IDs start with `csis-csa-resources-` and have a random suffix |
| Service account | `csis-csa-collector@<project-id>.iam.gserviceaccount.com` |
| Project organization-policy override | Disables enforcement of `constraints/iam.disableServiceAccountKeyUpload` to allow public-key upload |
| Service account key | Public certificate from `deploy-certificate.pem`; an existing matching key is reused |
| Organization custom role | `csis_collector_role_<project-suffix>`, with the permissions defined in `ROLE_PERMISSIONS` in `deploy.sh` |
| Organization IAM binding | Grants that custom role to the collector service account |
| Workspace delegation (manual, optional) | Authorizes the service account client ID for the scopes printed from `SCOPES` in `deploy.sh` |

The enabled APIs cover Resource Manager, IAM, IAM Credentials, Logging, Cloud Asset, Service Usage, Essential Contacts, Security Command Center, Storage, Cloud Run, Admin SDK, Cloud Identity, API Keys, and Organization Policy.

## Cleanup

Run from this repository's directory so the script can load the organization saved in `.deploy_config`, or select an organization when prompted:

```bash
bash cleanup.sh
```

The script discovers projects whose IDs begin with `csis-csa-resources-` directly under the selected organization and organization custom roles beginning with `csis_collector_role_`. It lists matching projects, roles, and role bindings, and requires `yes` before removing the bindings, deleting the roles, and scheduling project deletion. Discovery failures stop cleanup before any deletions.

**Cleanup covers all matching deployments in the selected organization**, not just the saved collector ID. Projects moved under folders or reused projects with a different ID prefix are not discovered; inspect and remove those separately if applicable.

Project deletion also removes the collector service account, its uploaded certificate key, enabled API configuration, and project policy override. Google Cloud may allow project recovery only during its retention period. The local `.deploy_config` is removed after successful cleanup; `deploy-certificate.pem` is retained.

**Google Workspace Domain-Wide Delegation is not removed automatically.** Record the collector's client ID before deleting its project, then remove that client entry from [Domain-Wide Delegation](https://admin.google.com/ac/owl/domainwidedelegation). This also applies when cleanup finds no remaining cloud resources.

Cleanup requires permission to list projects and organization roles, read and modify organization IAM bindings, delete custom roles, and delete the matching projects. It uses the active `gcloud` account and prompts for login if needed.

## Security Notes

- The organization custom role is scoped to assessment permissions; its exact permission list is maintained in `deploy.sh`.
- The uploaded certificate is public. The corresponding private key is not created or stored locally by these scripts.
- Public-key upload is allowed at the project level, not by changing the organization's default policy.
- Local `gcloud` credentials and `.deploy_config` persist after deployment. Cleanup does not revoke local Google Cloud credentials or remove Workspace delegation.

## Support

For issues or questions, refer to the CSIS Cloud Security Assessment documentation.
