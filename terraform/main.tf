resource "aws_ecr_repository" "cloudcourt" {
  name                 = "cloudcourt-stats"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "cloudcourt-stats-cicd"
  }
}
data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "cloudcourt_sg" {
  name        = "cloudcourt-sg"
  description = "Allow API traffic to CloudCourt Stats"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "API access"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = "cloudcourt-stats-cicd"
  }
}

resource "aws_iam_role" "ec2_ecr_role" {
  name = "cloudcourt-ec2-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "cloudcourt_profile" {
  name = "cloudcourt-instance-profile"
  role = aws_iam_role.ec2_ecr_role.name
}
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
}

resource "aws_instance" "cloudcourt_server" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = "t4g.micro"
  vpc_security_group_ids = [aws_security_group.cloudcourt_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cloudcourt_profile.name

  # Images are tagged by commit SHA, so there is no fixed tag to bootstrap from.
  # A fresh instance resolves the most recently pushed image out of ECR instead.
  # (ecr:DescribeImages comes from AmazonEC2ContainerRegistryReadOnly, already
  # attached to this instance profile.)
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf install -y docker
    systemctl enable --now docker

    REPO_URL="${aws_ecr_repository.cloudcourt.repository_url}"

    aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin "$REPO_URL"

    IMAGE_TAG=$(aws ecr describe-images \
      --repository-name ${aws_ecr_repository.cloudcourt.name} \
      --region us-east-1 \
      --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
      --output text)

    if [ "$IMAGE_TAG" = "None" ] || [ -z "$IMAGE_TAG" ]; then
      echo "No image in ECR yet — push to main to trigger the pipeline."
      exit 0
    fi

    docker pull "$REPO_URL:$IMAGE_TAG"
    docker run -d -p 5000:5000 --restart unless-stopped "$REPO_URL:$IMAGE_TAG"
  EOF

  tags = {
    Name    = "cloudcourt-server"
    Project = "cloudcourt-stats-cicd"
  }
}

output "api_url" {
  value = "http://${aws_instance.cloudcourt_server.public_ip}:5000"
}
