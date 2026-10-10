data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "ApiGatewayAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = "Lets API Gateway read one DynamoDB table (no Lambda in the path)"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags
}

# Least privilege: the listed read actions on exactly one table. Index and stream ARNs are not included.
data "aws_iam_policy_document" "read" {
  statement {
    sid       = "ReadOneTable"
    actions   = var.actions
    resources = [var.table_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read.json
}
