# Attack path summary
# 1. Anyone in the caller account can subscribe to and publish to the SNS topic
# 2. They SNS topic has a lambda function subscribed to it, which contains an RCE vulnerability
# 3. An attacker who has any type of AWS access to the account can send an RCE payload to the SNS topic and execute code on the lambda function
# 4. The lambda function has a role with a policy that allows it to read secrets from SSM, which contains the flag


resource "aws_iam_role" "lambda-sns-role" {
  name                = "ream"
  assume_role_policy  = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
  managed_policy_arns = [aws_iam_policy.lambda-sns-policy.arn, aws_iam_policy.lambda-sns-secret-policy.arn]
}

resource "aws_iam_policy" "lambda-sns-policy" {
  name        = "lambda-sns-policy"
  path        = "/"
  description = "Low priv policy used by lambdas"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [      
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTopics",
      "sns:ListSubscriptions",
      "sns:GetTopicAttributes",
      "sns:Receive",
      "ssm:DescribeParameters",

    ],
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_policy" "lambda-sns-secret-policy" {
  name        = "lambda-sns-secret-policy"
  path        = "/"
  description = ""

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action = "ssm:GetParameter"
        Resource = aws_ssm_parameter.lambda-sns-secret.arn
      },
    ]
  })
}


# // attach the secret policy to the role
# resource "aws_iam_role_policy_attachment" "lambda-sns-secret-policy-attachment" {
#   role       = aws_iam_role.lambda-sns-role.name
#   policy_arn = aws_iam_policy.lambda-sns-secret-policy.arn
# }




data "archive_file" "lambda-sns_zip" {
    type          = "zip"
    source_file   = "data/challenge-sns-lambda/src/index.js"
    output_path   = "data/challenge-sns-lambda/lambda_function.zip"
}


// lambda function that is triggered by sns that uses the lambda-sns_zip data
// lambda to accept sns messages
resource "aws_lambda_function" "lambda-sns" {
  filename         = "data/challenge-sns-lambda/lambda_function.zip"
  function_name    = "lambda-sns"
  role             = aws_iam_role.lambda-sns-role.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.lambda-sns_zip.output_base64sha256
  runtime          = "nodejs14.x"
}




// sns topic that sends messages to a lambda function
resource "aws_sns_topic" "test_sns" {
  name = "lambda-sns" 
}

// allow anyone in this account to publish to the topic
resource "aws_sns_topic_policy" "lambda-sns" {
  arn = aws_sns_topic.test_sns.arn

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "snspolicy",
  "Statement": [
    {
      "Sid": "First",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["sns:Subscribe", "sns:Publish"],
      "Resource": "${aws_sns_topic.eventbridge_sns.arn}",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalAccount": "${var.account_id}"
        }
      }
    }
  ]
}
POLICY
}




resource "aws_sns_topic_subscription" "test_sns_subscription" {
  topic_arn = aws_sns_topic.test_sns.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.lambda-sns.arn
}

// aws lambda permission to allow sns to invoke the lambda function
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda-sns.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.test_sns.arn
}



resource "aws_ssm_parameter" "lambda-sns-secret" {
  name  = "/cloudfoxable/flag/lambda-sns"
  type  = "SecureString"
  value = "{FLAG:WeJustPoppedALambdaByInjectingAnEvilSNSmessage}"
}


resource "aws_iam_role" "event_bridge_sns_rce_role" {
  name = "event_bridge_sns_rce_role"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "scheduler.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "event_bridge_sns_rce_role"
    Environment = "cloudfox"
  }
}

resource "aws_iam_policy" "event_bridge_sns_rce_policy" {
  name        = "event_bridge_sns_rce_policy"
  path        = "/"
  description = "Low priv policy used by lambdas"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [      
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTopics",
      "sns:ListSubscriptions",
      "sns:GetTopicAttributes",
      "sns:Receive",
      "sns:Publish",

    ],
        Effect   = "Allow"
        Resource = "${aws_sns_topic.test_sns.arn}"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "event_bridge_sns_rce_policy_attachment" {
  role       = aws_iam_role.event_bridge_sns_rce_role.name
  policy_arn = aws_iam_policy.event_bridge_sns_rce_policy.arn
}

// eventbridge schedule to send message to sns topic every minute
resource "aws_scheduler_schedule" "eventbridge_sns_rce" {
  name                = "eventbridge_sns_rce"
  description         = "sends sns message to topic"
  flexible_time_window {
    mode = "OFF"
  }

schedule_expression = "rate(1 minutes)"

target {
  arn      = aws_sns_topic.test_sns.arn
  role_arn = aws_iam_role.event_bridge_sns_rce_role.arn


  
  input = "echo \"hello world\" > /tmp/hello.txt"
  
  }
}
