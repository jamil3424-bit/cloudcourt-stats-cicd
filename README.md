# CloudCourt Stats API — Terraform-Provisioned CI/CD on AWS

A containerized Flask API whose entire environment is defined as code and shipped by an automated pipeline: **push to `main` → tests gate the build → GitHub Actions builds an ARM64 image → pushes it to ECR tagged with the commit SHA → redeploys the running EC2 container via SSM → fails the run unless `/health` returns 200.** No console clicking, no SSH, and no long-lived AWS keys.

The API itself is deliberately small (a basketball stats endpoint). The point of the project is everything around it — the infrastructure, the pipeline, and the deploy path.

---

## Architecture

```
 git push (main)
       │
       ▼
   pytest ──► red? pipeline stops here, nothing is built
       │
       │ needs: test
       ▼
 GitHub Actions ──► docker buildx (linux/arm64) ──► Amazon ECR
   (OIDC role,          tagged :<commit-sha>          │
    no static keys)                                   │
       │                                              │
       │ aws ssm send-command                         │ docker pull
       ▼                                              ▼
 EC2 t4g.micro (Graviton, AL2023) ◄───────────────────┘
       │
       ▼
 Flask + gunicorn :5000 ──► /health must return 200 or the deploy fails
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
| `aws_iam_openid_connect_provider` | Trusts GitHub's OIDC issuer so CI holds **no long-lived AWS credentials** |
| `aws_iam_role` (`gha-deploy-role`) | The CI identity, assumed via web identity, with a hand-written least-privilege policy (below) |

The instance bootstraps itself through `user_data`: install Docker, authenticate to ECR, pull, run with `--restart unless-stopped`.

### Keyless CI, and a least-privilege role

There is no `AWS_ACCESS_KEY_ID` in this repository. GitHub mints a short-lived
OIDC token per run and AWS exchanges it for temporary role credentials. The
trust policy pins **both** conditions:

```
aud = sts.amazonaws.com
sub = repo:jamil3424-bit/cloudcourt-stats-cicd:ref:refs/heads/main
```

A fork, a pull request, or any other repository presents a different `sub` and
is refused by STS before a single permission is evaluated. The only GitHub
secret is `AWS_DEPLOY_ROLE_ARN` — an ARN, not a credential.

The role itself gets five scoped statements rather than a managed policy:

- `ecr:GetAuthorizationToken` — `*` (the API requires it; it grants no data access on its own)
- ECR push/pull layer actions — **scoped to this repository's ARN**, not all of ECR
- `ec2:DescribeInstances` — `*` (read-only; the describe APIs don't take a resource ARN)
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
# Tests — the same suite the pipeline gates on
pip install -r requirements-dev.txt
pytest tests/ -v

# Infrastructure
cd terraform
terraform init
terraform apply          # outputs api_url and gha_deploy_role_arn

# Verify
curl http://<public-ip>:5000/health

# Tear down — this project is applied and destroyed per demo
terraform destroy
```

CI requires exactly one repository secret: **`AWS_DEPLOY_ROLE_ARN`**, set to the
`gha_deploy_role_arn` output above.

> If the AWS account already has GitHub registered as an OIDC provider, import
> it instead of creating a duplicate:
> ```bash
> terraform import aws_iam_openid_connect_provider.github \
>   arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
> ```

State is local and **gitignored** (`terraform/*.tfstate`) — it is not in this repository.

---

## Engineering decisions worth calling out

**Graviton required a cross-platform build.** A `t4g` instance is ARM64, but GitHub's runners are x86. The first pipeline built an image the instance could not execute. Fixed with `docker/setup-buildx-action` and an explicit `--platform linux/arm64`.

**Apply → deploy → destroy, repeatedly.** The environment is rebuilt from scratch rather than kept running, which both proves the Terraform is genuinely reproducible and holds spend at zero between demos.

**A torn-down environment is not a failed build.** Because the infrastructure only exists during a demo, a push on any other day has nothing to deploy to. A `preflight` job checks for a running instance first: if there isn't one it emits a notice and the deploy job is **skipped**, so tests still run and the pipeline reflects reality instead of going red over a deliberate cost decision. It never reports a deploy that didn't happen — the deploy either runs and is health-checked, or it is visibly skipped.

**Dependency layer ordering.** Copying `requirements.txt` ahead of `app/` means an application change doesn't reinstall Flask and gunicorn.

**`send-command` is fire-and-forget.** It returns a command ID the moment SSM accepts the request, not when the container is running. Trusting that return value would turn every deploy green regardless of outcome, so the pipeline polls `get-command-invocation` until the command reaches a terminal state and prints the instance's stdout and stderr when it fails. The remote command ends in `curl --fail http://localhost:5000/health`, which makes a container that starts and immediately crashes a **failed deploy** rather than a silent one.

**Bootstrapping without a fixed tag.** Once images are SHA-tagged there is no stable tag for a fresh instance to pull, so `user_data` queries ECR for the most recently pushed image (`sort_by(imageDetails,&imagePushedAt)[-1]`) and exits cleanly if the repository is still empty.

---

## Known limitations

Honest scope notes — these are deliberate cuts for a portfolio build, not oversights:

- **Mutable tags.** Tags are unique per commit, but the repository is still `MUTABLE`. `IMMUTABLE` would be stricter; it also makes re-running a workflow on an unchanged commit fail on push, which wasn't a trade worth making here.
- **Port 5000 open to `0.0.0.0/0`** and plain HTTP — no ALB, no TLS, no custom domain.
- **Single instance, no autoscaling** — there is a brief gap while the old container stops and the new one starts.
- **Local Terraform state.** Fine for a single operator; a real team needs an S3 backend with DynamoDB locking.
- **No rollback automation.** Every prior SHA is a valid rollback target, but redeploying one is currently a manual `docker run`.

---

**Stack:** Terraform · Docker · GitHub Actions (OIDC) · Amazon ECR · EC2 Graviton · IAM · SSM · Flask · pytest
