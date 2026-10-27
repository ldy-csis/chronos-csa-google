# Chronos CSA - Google Cloud Security Assessment Tool

A deployment toolkit for the Chronos Cloud Security Assessment (CSA) tool that configures access to a Google Cloud organization and, optionally, Google Workspace.

## Overview

`deploy.sh` offers to create a dedicated Google Cloud project (recommended) or deploy into an existing project in the selected organization, enables the required APIs, creates a collector service account, and uploads the CSIS public certificate as a service account key. It creates or updates an organization-level custom audit role and binds it to the service account.

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

2. **Provide the Super Admin email and select your organization** when prompted. Then choose **Create a new project (recommended)** or **Select an existing project**. Existing project choices include accessible active projects directly under the organization or in its folders. Review the deployment summary, including the project ID, and type `yes` to create or update resources.

3. **Configure Google Workspace Domain-Wide Delegation** if Workspace collection is wanted:
   - Open [Domain-Wide Delegation](https://admin.google.com/ac/owl/domainwidedelegation).
   - Add a client using the service account client ID and the exact comma-separated OAuth scopes printed by the script.
   - Return to the script and answer `yes` once configured, or `no` to finish without Workspace delegation.

3. **Choose project access** when prompted: **All projects (organization-wide access)** binds the audit role on the organization, as before. **Selected projects** lists the organization's accessible active projects; enter the numbers of the projects to grant, and the role is bound on each of those projects only. Organization-level permissions in the role (for example `resourcemanager.organizations.get`) have no effect on a project-level binding, so organization-wide findings are not collected in this mode.

The script submits the collector ID, project number, organization name, service account email, and uploaded key ID to `https://csa.cs-staging.csis.com/<COLLECTOR_ID>/Google/api/submit/`. The Super Admin email is included only when delegation is confirmed.

After deployment is approved, `.deploy_config` saves `COLLECTOR_ID`, `SUPER_ADMIN_EMAIL`, `SELECTED_ORG_ID`, `ACCESS_MODE` (`all` or `selected`), and `ACCESS_PROJECT_IDS` (space-separated, for `selected`) in the current directory. Once the project is active, it also saves `PROJECT_ID` so later runs reuse it without prompting for a project again. You can also supply `PROJECT_ID` through the environment. Later runs load this file, and its values take precedence over environment variables and the collector ID argument. Edit or remove it before deploying for a different collector, organization, or project. Do not commit this local configuration.

## Deployment Safeguards

Before changing cloud resources, the script checks that the active account can read the organization, its IAM policy, and custom roles. It displays a deployment summary and requires `yes` to proceed; any other response exits without creating resources or saving deployment configuration. Authentication may still update local credentials before this confirmation.

After the project is available, the script checks project access and waits with bounded retries for the project, enabled APIs, and service account to become available. These checks do not preflight every required create or update permission; later commands can still fail if access is missing.

Before uploading, the script lists the service account keys and looks for the expected key ID configured in `DEPLOY_KEY_ID`. An existing enabled key is reused without changing the upload policy or uploading again. If that key is disabled, deployment stops with an error; unrelated keys do not prevent upload.

Existing projects, including projects supplied through configuration or the environment, must be active and belong to the selected organization. Their organization ancestry and project access are checked before deployment confirmation. Selecting an existing project changes its enabled APIs and may change its public-key upload policy; a new dedicated project is recommended to isolate these changes.

## What Gets Created or Updated

| Resource | Configuration |
|----------|---------------|
| Project | New dedicated project with display name `CSIS-CSA-Resources` and a randomly suffixed `csis-csa-resources-` ID, or the selected existing project |
| Service account | `csis-csa-collector@<project-id>.iam.gserviceaccount.com` |
| Project organization-policy override | Disables enforcement of `constraints/iam.disableServiceAccountKeyUpload` to allow public-key upload |
| Service account key | Public certificate from `deploy-certificate.pem`; an existing matching key is reused |
| Organization custom role | `csis_collector_role_<project-suffix>`, with the permissions defined in `ROLE_PERMISSIONS` in `deploy.sh` |
| IAM binding | Grants that custom role to the collector service account on the organization (all projects) or on each selected project |
| Workspace delegation (manual, optional) | Authorizes the service account client ID for the scopes printed from `SCOPES` in `deploy.sh` |

The enabled APIs cover Resource Manager, IAM, IAM Credentials, Logging, Cloud Asset, Service Usage, Essential Contacts, Security Command Center, Storage, Cloud Run, Admin SDK, Cloud Identity, API Keys, and Organization Policy.

## Cleanup

Run from this repository's directory so the script can load the organization saved in `.deploy_config`, or select an organization when prompted:

```bash
bash cleanup.sh
```

Cleanup only touches resources it can prove were created by `deploy.sh`:

- **Projects** are scheduled for deletion only if the ID starts with `csis-csa-resources-`, the name is `CSIS-CSA-Resources`, the project belongs to the selected organization, and it contains the `csis-csa-collector` service account carrying the CSIS certificate key.
- **Roles** are deleted only if the ID starts with `csis_collector_role_` and the title is `CSIS Collector role`, and no principal other than our collector service accounts is bound to it. A role with other principals bound is kept.
- **Bindings** are removed only for `csis-csa-collector` service accounts in the projects identified above, on the organization and on accessible projects ("Selected projects" access).
- **A reused project** (named by `PROJECT_ID` in `.deploy_config`) is never deleted; only its `csis-csa-collector` service account is deleted, and only if it carries the CSIS certificate key. Its project policy and enabled APIs are left unchanged, including the key-upload override.

It lists everything and requires `yes` before making changes. Discovery failures stop cleanup before any deletions.

**Cleanup covers all matching deployments in the selected organization**, not just the saved collector ID. Without `.deploy_config`, a reused project's `csis-csa-collector` service account must be removed manually.

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
