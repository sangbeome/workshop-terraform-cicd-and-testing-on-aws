terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" { region = "us-east-1" }

# ============================================================
# Lambda Function
# ============================================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content  = <<-EOF
      import json
      def lambda_handler(event, context):
          return {'statusCode': 200, 'body': json.dumps('Hello from CICD')}
    EOF
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

resource "aws_lambda_function" "api_handler" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "cicd-api-handler"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
}

# ============================================================
# API Gateway REST API
# ============================================================
resource "aws_api_gateway_rest_api" "main" {
  name        = "cicd-test-api"
  description = "CICD Test API Gateway"
}

resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "orders"
}

resource "aws_api_gateway_method" "orders_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.orders.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "orders_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.orders.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "orders_get_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.orders_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_handler.invoke_arn
}

resource "aws_api_gateway_integration" "orders_post_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.orders_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_handler.invoke_arn
}

# Lambda permission - API Gateway가 Lambda를 호출할 수 있는 권한
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# BUG 1: Implicit ordering - deployment가 lambda_permission, integration 완료 전에 실행될 수 있음
#         depends_on이 없어서 Terraform이 병렬로 실행하면 race condition 발생
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # triggers로 재배포 조건은 걸었지만, 순서 보장이 안 됨
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.orders.id,
      aws_api_gateway_method.orders_get.id,
      aws_api_gateway_method.orders_post.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "prod"
}

# ============================================================
# DynamoDB Table
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

  tags = { Environment = "Test", ManagedBy = "Terraform" }
}

# BUG 2: Lambda에 DynamoDB 접근 권한을 주는 policy인데,
#         policy가 DynamoDB table ARN을 참조하고, Lambda role에 attach하지만
#         Lambda function의 environment variables에서 table name을 설정하는 부분이
#         이 policy attachment와 ordering이 보장되지 않음
#         → Lambda가 배포된 직후 DynamoDB 접근 시 AccessDenied 가능
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "lambda-dynamodb-access"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem"
      ]
      Resource = [
        aws_dynamodb_table.orders.arn,
        "${aws_dynamodb_table.orders.arn}/index/*"
      ]
    }]
  })
}

# ============================================================
# SNS + SQS Fan-out
# ============================================================
resource "aws_sns_topic" "order_events" {
  name = "cicd-order-events"
}

resource "aws_sqs_queue" "order_processing" {
  name                       = "cicd-order-processing"
  visibility_timeout_seconds = 60
}

resource "aws_sqs_queue" "order_analytics" {
  name                       = "cicd-order-analytics"
  visibility_timeout_seconds = 60
}

# BUG 3: SQS Queue Policy가 SNS topic ARN을 참조하지만,
#         SNS subscription이 이 policy보다 먼저 생성되면
#         SNS가 SQS에 메시지를 보내려 할 때 권한 에러
#         subscription과 policy 사이에 depends_on이 없음
resource "aws_sqs_queue_policy" "order_processing_policy" {
  queue_url = aws_sqs_queue.order_processing.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.order_processing.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.order_events.arn }
      }
    }]
  })
}

resource "aws_sqs_queue_policy" "order_analytics_policy" {
  queue_url = aws_sqs_queue.order_analytics.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.order_analytics.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.order_events.arn }
      }
    }]
  })
}

# SNS → SQS subscriptions (policy 완료 전에 생성될 수 있음)
resource "aws_sns_topic_subscription" "order_processing_sub" {
  topic_arn = aws_sns_topic.order_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.order_processing.arn
}

resource "aws_sns_topic_subscription" "order_analytics_sub" {
  topic_arn = aws_sns_topic.order_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.order_analytics.arn
}

# ============================================================
# CloudWatch Alarms + Auto Scaling (implicit ordering issue)
# ============================================================
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "cicd-api-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "API 5XX errors exceeded threshold"

  # BUG 4: stage_name을 직접 문자열로 하드코딩하지 않고 stage 리소스에서 참조하지만,
  #         alarm이 stage보다 먼저 생성되면 dimension 값이 아직 유효하지 않을 수 있음
  dimensions = {
    ApiName = aws_api_gateway_rest_api.main.name
    Stage   = aws_api_gateway_stage.prod.stage_name
  }

  alarm_actions = [aws_sns_topic.order_events.arn]
}

# ============================================================
# S3 + Lambda Event Notification (classic ordering trap)
# ============================================================
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "uploads" {
  bucket = "cicd-uploads-${random_id.bucket_suffix.hex}"
  tags   = { Environment = "Test", ManagedBy = "Terraform" }
}

# BUG 5: S3 bucket notification이 lambda_permission보다 먼저 생성되면
#         S3가 Lambda를 호출할 권한이 없어서 notification 설정 자체가 실패
#         이건 apply 시 실제 에러가 발생하는 케이스
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.uploads.arn
}

resource "aws_s3_bucket_notification" "upload_trigger" {
  bucket = aws_s3_bucket.uploads.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.api_handler.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "incoming/"
  }
  # depends_on = [aws_lambda_permission.s3_invoke]  # 이게 없으면 race condition
}

# ============================================================
# Outputs
# ============================================================
output "api_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/orders"
}
output "lambda_function_name" {
  value = aws_lambda_function.api_handler.function_name
}
output "dynamodb_table_name" {
  value = aws_dynamodb_table.orders.name
}
output "upload_bucket" {
  value = aws_s3_bucket.uploads.id
}
