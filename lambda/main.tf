terraform {
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 6.0" }
    random   = { source = "hashicorp/random", version = "~> 3.0" }
    archive  = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" { region = "us-east-1" }

# ============================================================
# 1. Lambda Function (기존)
# ============================================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content  = "import json\ndef lambda_handler(event, context):\n    return {'statusCode': 200, 'body': json.dumps('Hello from CICD')}"
    filename = "lambda_function.py"
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "cicd-test-lambda-role"
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

resource "aws_lambda_function" "test_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "cicd-test-lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.orders.name
      QUEUE_URL  = aws_sqs_queue.order_queue.url
      TOPIC_ARN  = aws_sns_topic.notifications.arn
    }
  }
}

# ============================================================
# 2. S3 Bucket
# ============================================================
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
  versioning_configuration { status = "Enabled" }
}

# ============================================================
# 3. DynamoDB Table
# ============================================================
resource "aws_dynamodb_table" "orders" {
  name         = "cicd-test-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"
  range_key    = "timestamp"

  attribute {
    name = "orderId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }
  attribute {
    name = "customerId"
    type = "S"
  }

  global_secondary_index {
    name            = "CustomerIndex"
    hash_key        = "customerId"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  tags = { Environment = "Test", ManagedBy = "Terraform" }
}

# ============================================================
# 4. SQS Queue + Dead Letter Queue
# ============================================================
resource "aws_sqs_queue" "order_dlq" {
  name                      = "cicd-test-order-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "order_queue" {
  name                       = "cicd-test-order-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 3
  })
}

# Lambda SQS trigger
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.order_queue.arn
  function_name    = aws_lambda_function.test_lambda.arn
  batch_size       = 10
}

# ============================================================
# 5. SNS Topic + Subscription
# ============================================================
resource "aws_sns_topic" "notifications" {
  name = "cicd-test-notifications"
}

# ============================================================
# 6. CloudWatch Alarm
# ============================================================
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "cicd-test-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda error rate too high"
  alarm_actions       = [aws_sns_topic.notifications.arn]

  dimensions = {
    FunctionName = aws_lambda_function.test_lambda.function_name
  }
}

# ============================================================
# 7. [BUG] Second Lambda - 잘못된 runtime 지정
#    python3.99는 존재하지 않는 runtime → 리소스 생성 실패
# ============================================================
data "archive_file" "processor_zip" {
  type        = "zip"
  output_path = "${path.module}/processor.zip"
  source {
    content  = "import json\ndef handler(event, context):\n    return {'statusCode': 200, 'body': 'processed'}"
    filename = "processor.py"
  }
}

resource "aws_lambda_function" "order_processor" {
  filename         = data.archive_file.processor_zip.output_path
  function_name    = "cicd-order-processor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "processor.handler"
  source_code_hash = data.archive_file.processor_zip.output_base64sha256
  runtime          = "python3.99"  # BUG: 존재하지 않는 runtime
  timeout          = 60
  memory_size      = 512
}

# ============================================================
# 8. [BUG] IAM Policy - 존재하지 않는 managed policy 참조
# ============================================================
resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v99"  # BUG: 존재하지 않는 정책
}

# ============================================================
# 9. [BUG] S3 Bucket Notification - 존재하지 않는 Lambda 참조
# ============================================================
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.test_bucket.id

  lambda_function {
    lambda_function_arn = "arn:aws:lambda:us-east-1:937743225658:function:non-existent-function"  # BUG: 존재하지 않는 함수
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }
}

# ============================================================
# Outputs
# ============================================================
output "bucket_name" {
  value = aws_s3_bucket.test_bucket.id
}
output "lambda_function_name" {
  value = aws_lambda_function.test_lambda.function_name
}
output "dynamodb_table_name" {
  value = aws_dynamodb_table.orders.name
}
output "sqs_queue_url" {
  value = aws_sqs_queue.order_queue.url
}
output "sns_topic_arn" {
  value = aws_sns_topic.notifications.arn
}
