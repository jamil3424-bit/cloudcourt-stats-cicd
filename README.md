# CloudCourt Stats API — Terraform-Provisioned CI/CD on AWS

A containerized Flask API whose entire environment is defined as code and shipped by an automated pipeline: **push to `main` → GitHub Actions builds an ARM64 image → pushes to ECR → redeploys the running EC2 container via SSM.** No console clicking, no SSH.

The API itself is deliberately small (a basketball stats endpoint). The point of the project is everything around it — the infrastructure, the pipeline, and the deploy path.

---

## Architecture

```
 git push (main)
       │
       ▼
 GitHub Actions ──► docker buildx (linux/arm64) ──► Amazon ECR
       │                                              │
       │ aws ssm send-command                         │ docker pull
       ▼                                              ▼
 EC2 t4g.micro (Graviton, AL2023) ◄───────────────────┘
       │
       ▼
 Flask + gunicorn, port 5000
```

**Deploys over SSM, not SSH.** The pipeline never opens an SSH connection and no key material exists for the instance. GitHub Actions calls `ssm:SendCommand`, and the instance pulls its own image using an instance-profile role. That removes the "where do I store the deploy key" problem entirely.

---

## What's provisioned (`terraform/`)

| Resource | Detail |
|---|---|
| `aws_ecr_repository` | `cloudcourt-stats`, with `scan_on_push` enabled |
| `aws_instance` | `t4g.micro` — **Graviton/ARM64**, chosen for lower cost per request than equivalent x86 |
| `aws_ami` (data) | Latest Amazon Linux 2023 `arm64`, resolved at plan time rather than pinned to a stale ID |
| `aws_security_group` | Ingress on `5000` only; all egress |
| `aws_iam_role` + instance profile | EC2 gets `AmazonEC2ContainerRegistryReadOnly` + `AmazonSSMManagedInstanceCore` — read ECR, be managed by SSM, nothing more |
| `aws_iam_user` (`gha-deploy`) | The CI identity, with a hand-written least-privilege policy (below) |

The instance bootstraps itself through `user_data`: install Docker, authenticate to ECR, pull, run with `--restart unless-stopped`.

### Least-privilege CI policy

The pipeline user gets four scoped statements rather than a managed policy:

- `ecr:GetAuthorizationToken` — `*` (the API requires it; it grants no data access on its own)
- ECR push/pull layer actions — **scoped to this repository's ARN**, not all of ECR
- `ssm:SendCommand` — **scoped to the `AWS-RunShellScript` document and this account's instances**
- `ssm:GetCommandInvocation` — to read back the deploy result

No `AdministratorAccess`, no `PowerUserAccess`, no wildcard resource on the actions that actually move data.

---

## The API

| Route | Returns |
|---|---|
| `GET /` | Service name + status |
| `GET /players` | Player stat objects |
| `GET /health` | `{"status": "healthy"}` — the deploy health check |

Served by **gunicorn**, not the Flask dev server. Image base is `python:3.12-slim`, with `requirements.txt` copied and installed *before* application code so dependency layers stay cached across code-only rebuilds.

---

## Running it

```bash
# Infrastructure
cd terraform
terraform init
terraform apply          # outputs api_url

# Verify
curl http://<public-ip>:5000/health

# Tear down — this project is applied and destroyed per demo
terraform destroy
```

CI requires two repository secrets: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for the `cloudcourt-gha-deploy` user.

State is local and **gitignored** (`terraform/*.tfstate`) — it is not in this repository.

---

## Engineering decisions worth calling out

**Graviton required a cross-platform build.** A `t4g` instance is ARM64, but GitHub's runners are x86. The first pipeline built an image the instance could not execute. Fixed with `docker/setup-buildx-action` and an explicit `--platform linux/arm64`.

**Apply → deploy → destroy, repeatedly.** The environment is rebuilt from scratch rather than kept running, which both proves the Terraform is genuinely reproducible and holds spend at zero between demos.

**Dependency layer ordering.** Copying `requirements.txt` ahead of `app/` means an application change doesn't reinstall Flask and gunicorn.

---

## Known limitations

Honest scope notes — these are deliberate cuts for a portfolio build, not oversights:

- **Static image tag.** Images are pushed as `:v1`, a mutable tag. Commit-SHA tagging would give real rollback targets and is the first thing to change for anything production-facing.
- **Long-lived IAM user credentials.** CI authenticates with an access key pair in GitHub secrets. GitHub's OIDC provider (`id-token: write` + a role trust policy) would remove the standing credential entirely.
- **No test stage.** The pipeline builds and deploys; it does not gate on tests.
- **Port 5000 open to `0.0.0.0/0`** and plain HTTP — no ALB, no TLS, no custom domain.
- **Single instance, no autoscaling** — there is a brief gap while the old container stops and the new one starts.

---

**Stack:** Terraform · Docker · GitHub Actions · Amazon ECR · EC2 Graviton · IAM · SSM · Flask
