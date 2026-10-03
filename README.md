# secure-serverless-api-aws

Terraform for a serverless API on AWS, built incrementally. Free-tier friendly: anything that
costs money is off by default and documented below.

## Layout

```
terraform/
├── modules/dynamodb-table/   # reusable, validated DynamoDB table module
└── environments/dev/         # root config: provider, tags, Orders table
```

## Orders table

| Setting | Value |
|---|---|
| Name | `Orders` |
| Partition key | `orderId` (S) |
| Sort key | `itemId` (S) |
| Capacity | On-demand (`PAY_PER_REQUEST`) |
| Encryption at rest | On, AWS-owned key (free) |
| Deletion protection | On (free) |
| Point-in-time recovery | **Off** (billed per GB, no free tier) |

Outputs: `orders_table_name`, `orders_table_arn` (use the ARN for least-privilege IAM later).

## Usage

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply   # creates a real table; on-demand, so cost is per request only
```

To destroy, first set `deletion_protection_enabled = false` in `environments/dev/main.tf` and apply.

## State

Local state for now (`*.tfstate` is git-ignored; it can hold sensitive data). Planned: S3 backend
with encryption and versioning.

## Cost switches (off until approved)

- `enable_point_in_time_recovery` — continuous backups, billed per GB.
- Customer-managed KMS key — monthly fee per key (not implemented).
