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
