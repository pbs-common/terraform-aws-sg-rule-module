
data "aws_vpc" "vpc" {
  tags = {
    "Name" : "*${var.environment}*"
  }
}

data "aws_subnets" "public_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*-public-*"]
  }
}

resource "aws_security_group" "instance_sg" {
  name        = "allow-nc"
  description = "Allow netcat testing"
  vpc_id      = data.aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_iam_role" "ec2_cloudwatch_role" {
  name = "${var.product}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cloudwatch_policy" {
  name = "${var.product}-policy"
  role = aws_iam_role.ec2_cloudwatch_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_cloudwatch_role.id
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.product}-instance-profile"
  role = aws_iam_role.ec2_cloudwatch_role.name
}

resource "aws_instance" "server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = data.aws_subnets.public_subnets.ids[0]
  # subnet_id = "subnet-0d5b1d6d278304fba"
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = false
  root_block_device {
    volume_size = 30
  }
  tags = {
    Name = "${var.product}-NC-Server"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nc amazon-cloudwatch-agent amazon-ssm-agent
              systemctl enable amazon-ssm-agent
              systemctl start amazon-ssm-agent

              echo "Server listening..." > /tmp/server.log
              nc -lk -p 12345 >> /tmp/server.log &

              # Write CloudWatch Agent config
              cat <<EOT > /opt/aws/amazon-cloudwatch-agent/bin/config.json
              {
              "logs": {
                "logs_collected": {
                  "files": {
                    "collect_list": [
                      {
                        "file_path": "/tmp/server.log",
                        "log_group_name": "${var.product}-log-group",
                        "log_stream_name": "{instance_id}/nc-server",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                      }
                    ]
                  }
                }
              }
              }
              EOT

              # Start the CloudWatch Agent
              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
              -a fetch-config \
              -m ec2 \
              -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json \
              -s
              EOF
}

resource "aws_instance" "client" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = data.aws_subnets.public_subnets.ids[0]
  # subnet_id = "subnet-0d5b1d6d278304fba"
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = false
  root_block_device {
    volume_size = 30
  }
  tags = {
    Name = "${var.product}-NC-Client"
  }

  depends_on = [aws_instance.server]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nc amazon-ssm-agent
              systemctl enable amazon-ssm-agent
              systemctl start amazon-ssm-agent
              for i in {1..100}; do
                echo "Hello from client" | nc ${aws_instance.server.private_ip} 12345;
                sleep 5;
              done
              EOF
}

module "sg_rule" {
  source = "../.."

  security_group_id        = aws_security_group.instance_sg.id
  description              = "Allow nc traffic on port 12345"
  port                     = 12345
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.instance_sg.id

  organization = var.organization
  environment  = var.environment
  product      = var.product
  owner        = var.owner
  repo         = var.repo
}

output "log_group" {
  value = "${var.product}-log-group"
}

output "log_stream" {
  value = "${aws_instance.server.id}/nc-server"
}