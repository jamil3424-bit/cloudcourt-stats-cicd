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

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y docker
    systemctl start docker
    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${aws_ecr_repository.cloudcourt.repository_url}
    docker pull ${aws_ecr_repository.cloudcourt.repository_url}:v1
    docker run -d -p 5000:5000 --restart unless-stopped ${aws_ecr_repository.cloudcourt.repository_url}:v1
  EOF

  tags = {
    Name    = "cloudcourt-server"
    Project = "cloudcourt-stats-cicd"
  }
}

output "api_url" {
  value = "http://${aws_instance.cloudcourt_server.public_ip}:5000"
}
