terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" { region = "us-east-1" }

# ============================================================
# Data Sources
# ============================================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# Security Groups
# ============================================================

# Lambda가 RDS에 접근할 때 사용하는 SG
resource "aws_security_group" "lambda_sg" {
  name        = "cicd-lambda-sg"
  description = "Security group for Lambda functions"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cicd-lambda-sg", ManagedBy = "Terraform" }
}

# RDS 인스턴스용 SG
# BUG: MySQL은 3306 포트를 사용하는데 5432(PostgreSQL)로 열어놓음
#      terraform apply는 성공하지만 Lambda → RDS 연결 시 timeout 발생
resource "aws_security_group" "rds_sg" {
  name        = "cicd-rds-sg"
  description = "Security group for RDS MySQL"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL access from Lambda"
    from_port       = 5432    # BUG: PostgreSQL 포트 — MySQL은 3306이어야 함
    to_port         = 5432    # BUG: PostgreSQL 포트 — MySQL은 3306이어야 함
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cicd-rds-mysql-sg", ManagedBy = "Terraform" }
}

# ============================================================
# RDS Subnet Group
# ============================================================
resource "aws_db_subnet_group" "main" {
  name       = "cicd-test-db-subnet"
  subnet_ids = slice(data.aws_subnets.default.ids, 0, 2)

  tags = { Name = "cicd-test-db-subnet", ManagedBy = "Terraform" }
}

# ============================================================
# RDS MySQL Instance
# ============================================================
resource "random_password" "db_password" {
  length  = 16
  special = false
}

resource "aws_db_instance" "mysql" {
  identifier     = "cicd-test-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "orders"
  username = "admin"
  password = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true
  publicly_accessible = false

  tags = { Name = "cicd-test-mysql", Environment = "Test", ManagedBy = "Terraform" }
}

# ============================================================
# Lambda Function (RDS에 연결하는 함수)
# ============================================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content  = <<-EOF
      import json, os, pymysql
      def lambda_handler(event, context):
          conn = pymysql.connect(
              host=os.environ['DB_HOST'],
              port=int(os.environ['DB_PORT']),
              user=os.environ['DB_USER'],
              password=os.environ['DB_PASS'],
              database=os.environ['DB_NAME'],
              connect_timeout=5
          )
          cursor = conn.cursor()
          cursor.execute("SELECT 1")
          return {'statusCode': 200, 'body': json.dumps('DB Connected')}
    EOF
    filename = "lambda_function.py"
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "cicd-db-connector-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "db_connector" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "cicd-db-connector"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = slice(data.aws_subnets.default.ids, 0, 2)
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      DB_HOST = aws_db_instance.mysql.address
      DB_PORT = "3306"
      DB_USER = "admin"
      DB_PASS = random_password.db_password.result
      DB_NAME = "orders"
    }
  }
}

# ============================================================
# Outputs
# ============================================================
output "rds_endpoint" {
  value = aws_db_instance.mysql.endpoint
}
output "lambda_function_name" {
  value = aws_lambda_function.db_connector.function_name
}
output "rds_sg_id" {
  value = aws_security_group.rds_sg.id
}
