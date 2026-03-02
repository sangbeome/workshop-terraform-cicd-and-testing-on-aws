terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
provider "aws" { region = "us-east-1" }
data "archive_file" "lambda_zip" {
  type = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content = "import json\ndef lambda_handler(event, context):\n    return {'statusCode': 200, 'body': json.dumps('Hello from CICD')}"
    filename = "lambda_function.py"
  }
}
resource "aws_iam_role" "lambda_role" {
  name = "cicd-test-lambda-role"
  assume_role_policy = jsonencode({Version="2012-10-17",Statement=[{Action="sts:AssumeRole",Effect="Allow",Principal={Service="lambda.amazonaws.com"}}]})
}
resource "aws_lambda_function" "test_lambda" {
  filename = data.archive_file.lambda_zip.output_path
  function_name = "cicd-test-lambda"
  role = aws_iam_role.lambda_role.arn
  handler = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime = "python3.12"
}

# S3 Bucket for testing CICD
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "test_bucket" {
  bucket = "terraform-cicd-test-${random_id.bucket_suffix.hex}"
  
  tags = {
    Name        = "Terraform CICD Test Bucket"
    Environment = "Test"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "test_bucket_versioning" {
  bucket = aws_s3_bucket.test_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

output "bucket_name" {
  value = aws_s3_bucket.test_bucket.id
}

output "lambda_function_name" {
  value = aws_lambda_function.test_lambda.function_name
}
