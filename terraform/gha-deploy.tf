data "aws_caller_identity" "current" {
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_user" "gha_deploy" {
  name = "cloudcourt-gha-deploy"

  tags = {
    Project = "cloudcourt-stats-cicd"
  }
}

resource "aws_iam_user_policy" "gha_deploy_policy" {
  name = "cloudcourt-gha-deploy-policy"
  user = aws_iam_user.gha_deploy.name

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
        Sid      = "SsmDeploy"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
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
