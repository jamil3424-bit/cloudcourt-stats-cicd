data "aws_caller_identity" "current" {
}

locals {
  github_repo = "jamil3424-bit/cloudcourt-stats-cicd"

  # The same repository as GitHub sometimes spells it in the OIDC `sub` claim,
  # with the immutable numeric owner and repository IDs attached.
  github_repo_qualified = "jamil3424-bit@301163393/cloudcourt-stats-cicd@1311640456"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- GitHub Actions OIDC ---------------------------------------------------
# GitHub issues each workflow run a short-lived OIDC token. AWS trusts that
# issuer directly, so CI assumes a role instead of holding an access key.
#
# If this account already has the GitHub provider registered, import it rather
# than creating a second one:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Project = "cloudcourt-stats-cicd"
  }
}

resource "aws_iam_role" "gha_deploy" {
  name        = "cloudcourt-gha-deploy-role"
  description = "Assumed by GitHub Actions via OIDC to build, push, and deploy CloudCourt Stats"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Scoped to pushes on main of this one repository. A fork, a pull
        # request, or any other repo presents a different subject and is
        # refused by STS before it ever reaches a permission check.
        #
        # Two accepted subjects, because GitHub does not always emit the
        # documented `repo:OWNER/NAME:ref:...` form — it may append the
        # immutable numeric owner and repository IDs (`OWNER@301163393`,
        # `NAME@1311640456`). Both are listed literally rather than matched
        # with a wildcard: a pattern like `jamil3424-bit*` would also accept
        # an account named `jamil3424-bit-something`. A list of exact strings
        # is an OR with no such widening.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${local.github_repo}:ref:refs/heads/main",
            "repo:${local.github_repo_qualified}:ref:refs/heads/main",
          ]
        }
      }
    }]
  })

  tags = {
    Project = "cloudcourt-stats-cicd"
  }
}

resource "aws_iam_role_policy" "gha_deploy_policy" {
  name = "cloudcourt-gha-deploy-policy"
  role = aws_iam_role.gha_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.cloudcourt.arn
      },
      {
        Sid      = "FindDeployTarget"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Sid    = "SsmDeploy"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:us-east-1::document/AWS-RunShellScript",
          "arn:aws:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"
        ]
      },
      {
        Sid      = "SsmCheckResult"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      }
    ]
  })
}

output "gha_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository secret in GitHub."
  value       = aws_iam_role.gha_deploy.arn
}
