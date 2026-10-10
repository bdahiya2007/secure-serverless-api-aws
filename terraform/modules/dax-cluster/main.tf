data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Role DAX assumes to read the table on the clients' behalf (read-only, one table)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "DaxAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dax.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dax" {
  name                 = "${var.name}-role"
  description          = "Lets DAX read one DynamoDB table"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags
}

data "aws_iam_policy_document" "read_table" {
  statement {
    sid       = "ReadOneTable"
    actions   = ["dynamodb:DescribeTable", "dynamodb:Query", "dynamodb:GetItem", "dynamodb:BatchGetItem"]
    resources = [var.table_arn]
  }
}

resource "aws_iam_role_policy" "dax" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.dax.id
  policy = data.aws_iam_policy_document.read_table.json
}

# ---------------------------------------------------------------------------
# Network: only clients in the client security group can reach the cluster, on the encrypted port
# ---------------------------------------------------------------------------

resource "aws_security_group" "client" {
  name        = "${var.name}-client"
  description = "Attach to the Lambda that talks to DAX"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-client" })
}

resource "aws_security_group" "dax" {
  name        = "${var.name}-cluster"
  description = "DAX cluster nodes"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-cluster" })
}

resource "aws_vpc_security_group_ingress_rule" "dax_from_client" {
  security_group_id            = aws_security_group.dax.id
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = 9111
  to_port                      = 9111
  description                  = "Encrypted DAX client traffic from the Lambda"
}

resource "aws_vpc_security_group_ingress_rule" "dax_from_nodes" {
  security_group_id            = aws_security_group.dax.id
  referenced_security_group_id = aws_security_group.dax.id
  ip_protocol                  = "tcp"
  from_port                    = 9111
  to_port                      = 9111
  description                  = "Traffic between nodes of the same cluster"
}

# DAX nodes must reach DynamoDB. If a demo shows they do not need this, narrow it.
resource "aws_vpc_security_group_egress_rule" "dax_out" {
  security_group_id = aws_security_group.dax.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "DAX to DynamoDB"
}

resource "aws_vpc_security_group_egress_rule" "client_to_dax" {
  security_group_id            = aws_security_group.client.id
  referenced_security_group_id = aws_security_group.dax.id
  ip_protocol                  = "tcp"
  from_port                    = 9111
  to_port                      = 9111
  description                  = "Lambda to DAX (encrypted)"
}

# ---------------------------------------------------------------------------
# DAX cluster (BILLED per node per hour, no free tier)
# ---------------------------------------------------------------------------

resource "aws_dax_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_dax_parameter_group" "this" {
  name = var.name

  parameters {
    name  = "query-ttl-millis"
    value = tostring(var.query_ttl_seconds * 1000)
  }

  parameters {
    name  = "record-ttl-millis"
    value = tostring(var.record_ttl_seconds * 1000)
  }
}

resource "aws_dax_cluster" "this" {
  cluster_name       = var.name
  iam_role_arn       = aws_iam_role.dax.arn
  node_type          = var.node_type
  replication_factor = var.replication_factor

  subnet_group_name    = aws_dax_subnet_group.this.name
  parameter_group_name = aws_dax_parameter_group.this.name
  security_group_ids   = [aws_security_group.dax.id]

  # Encrypted at rest, and clients connect over TLS (the daxs:// endpoint).
  server_side_encryption {
    enabled = true
  }
  cluster_endpoint_encryption_type = "TLS"

  tags = var.tags

  depends_on = [aws_iam_role_policy.dax]
}

# ---------------------------------------------------------------------------
# A Lambda inside the VPC has no internet access: give it a private path to CloudWatch Logs
# ---------------------------------------------------------------------------

resource "aws_security_group" "endpoint" {
  count = var.create_logs_endpoint ? 1 : 0

  name        = "${var.name}-logs-endpoint"
  description = "CloudWatch Logs interface endpoint"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-logs-endpoint" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoint_from_client" {
  count = var.create_logs_endpoint ? 1 : 0

  security_group_id            = aws_security_group.endpoint[0].id
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS from the Lambda"
}

resource "aws_vpc_security_group_egress_rule" "client_to_endpoint" {
  count = var.create_logs_endpoint ? 1 : 0

  security_group_id            = aws_security_group.client.id
  referenced_security_group_id = aws_security_group.endpoint[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Lambda to the CloudWatch Logs endpoint"
}

resource "aws_vpc_endpoint" "logs" {
  count = var.create_logs_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoint[0].id]
  private_dns_enabled = true
  tags                = var.tags
}
