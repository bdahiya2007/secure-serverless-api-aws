# Security policy

This is a personal portfolio project, not a supported product. Security reports are still welcome, and are handled on a best-effort basis.

## Reporting a vulnerability

Please report it **privately**, not in a public issue or pull request:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability** (GitHub private vulnerability reporting).
3. Describe what you found, where, and how to reproduce it. Do not include real credentials, tokens or other people's data.

You can expect an acknowledgement within about a week and a fix or a decision as time allows. Please give me a reasonable chance to fix the
issue before sharing details publicly.

## What is in scope

- The Terraform in `terraform/`, the Lambda code in `src/get-order/`, `src/save-order/` and `src/signin-guard/`, the browser front end in
  `src/frontend/`, the GitHub Actions workflows, the helper scripts and the documentation: for example a way past the Cognito authorizer or
  the request schema validation, a CORS or Content Security Policy weakness, a flaw in the PKCE sign-in flow or the Google sign-in allow-list
  guard, injection through an order or an order ID, a weakness in the deploy role's trust policy or permissions, or a secret committed by
  mistake.

## What is out of scope

- Findings that need access to the owner's AWS, GitHub or Google account.
- Weaknesses in AWS, GitHub or Google themselves.
- The gaps already listed under [Known limitations and roadmap](README.md#known-limitations-and-roadmap) in the README, which are known and
  tracked. This includes the missing ownership model (any signed-in user can read any order).
- Denial-of-service testing, load testing or any other testing against the deployed environment. The deployed stack belongs to the owner and
  is not offered for testing; please review the code instead.

## Supported versions

Only the latest commit on `main` is maintained.

## Keeping secrets out of the repository

`scripts/secret-scan.py` runs as a pre-commit hook (enable it once per clone with `./scripts/install-hooks.sh`) and again in CI on every
pull request. It looks for credentials, AWS account and resource IDs, personal data and state or key files, and reports matches without
printing the value. GitHub secret scanning with push protection is a second layer. Details and known limits:
[docs/SECRET_SCANNING.md](docs/SECRET_SCANNING.md).

The Google client secret and the sign-in allow-list are supplied at apply time and are never committed.

## If you find a secret

If you find what looks like a real credential in the repository or its history, report it privately as above. It will be rotated first,
then removed.
