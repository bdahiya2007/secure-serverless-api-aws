locals {
  api_dimensions    = ["ApiName", var.api_name, "Stage", var.stage_name]
  lambda_dimensions = ["FunctionName", var.function_name]

  # Only AWS-published service metrics (free). No logs queries or custom metrics, which would be billed.
  widgets = [
    {
      title      = "API Gateway: requests (Count)"
      namespace  = "AWS/ApiGateway"
      metric     = "Count"
      dimensions = local.api_dimensions
      x          = 0
      y          = 0
    },
    {
      title      = "API Gateway: client errors (4XXError)"
      namespace  = "AWS/ApiGateway"
      metric     = "4XXError"
      dimensions = local.api_dimensions
      x          = 12
      y          = 0
    },
    {
      title      = "Lambda: Invocations"
      namespace  = "AWS/Lambda"
      metric     = "Invocations"
      dimensions = local.lambda_dimensions
      x          = 0
      y          = 6
    },
    {
      title      = "Lambda: Errors"
      namespace  = "AWS/Lambda"
      metric     = "Errors"
      dimensions = local.lambda_dimensions
      x          = 12
      y          = 6
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      for w in local.widgets : {
        type   = "metric"
        x      = w.x
        y      = w.y
        width  = 12
        height = 6
        properties = {
          title   = w.title
          region  = var.region
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = var.period_seconds
          metrics = [concat([w.namespace, w.metric], w.dimensions)]
          yAxis   = { left = { min = 0 } }
        }
      }
    ]
  })
}
