# Secret scanning

This repository is public, so nothing secret, confidential or personal may be committed. One scanner,
[scripts/secret-scan.py](../scripts/secret-scan.py), enforces that in three places so the rules cannot drift apart.

| Where | When | Scope |
|---|---|---|
| **Pre-commit hook** (`.githooks/pre-commit`) | Every `git commit` on your machine | What is staged |
| **CI job** "Scan for secrets and sensitive data" (`validate.yml`) | Every pull request | Every tracked file, and every line added by every commit in the PR |
| **By hand** | Any time | `--staged`, `--all-tracked` or `--range BASE..HEAD` |

Only content that is committed (or about to be) is scanned. Git-ignored local files, such as `terraform.tfstate`, are not.

## What it blocks

| Category | Examples |
|---|---|
| Credentials | AWS access keys and secret keys, private key blocks, GitHub and Slack tokens, JWTs, a password or token assigned a literal value |
| AWS identifiers | An account ID inside an ARN, a 12-digit account ID in a resource name, deployed API, SSO and CloudFront hostnames, Cognito user pool IDs |
| Personal data | Email addresses (except `example.com`/`.org`/`.net` and `users.noreply.github.com`), personal file paths such as `/home/<user>/`, private IP addresses |
| Files that must never be committed | `*.tfstate`, `*.tfvars`, saved plans (`tfplan`, `*.tfplan`), `.env`, `*.pem`, `*.key`, `*credentials*`, `.terraform/`, `.aws/`, `.ssh/` (`.terraform.lock.hcl` is allowed) |
| Your own block list | Exact values you list, such as your account ID (see below) |

Use placeholders in docs and code: `ACCOUNT_ID`, `you@example.com`.

## Enable the hook (once per clone)

```bash
./scripts/install-hooks.sh        # sets git config core.hooksPath .githooks and runs the self-test
```

A blocked commit prints the rule, file and line with a **redacted** snippet, never the value itself.

## Block your own values (optional, kept out of the repo)

The built-in rules cannot know your account ID or email, and writing them in the repo would publish them. List them in a private
file instead, one per line:

```bash
mkdir -p ~/.config/secret-scan
printf '%s\n' 123456789012 you@example.com > ~/.config/secret-scan/literals && chmod 600 ~/.config/secret-scan/literals
```

For CI, store the same list as the repository secret `SECRET_SCAN_LITERALS` (one value per line). It is empty on pull
requests from forks, where only the built-in rules run:

```bash
gh secret set SECRET_SCAN_LITERALS -R <owner>/<repo> < ~/.config/secret-scan/literals
```

## Run it by hand

```bash
python3 scripts/secret-scan.py --staged                     # what you are about to commit
python3 scripts/secret-scan.py --all-tracked                # the whole tracked tree
python3 scripts/secret-scan.py --range origin/main..HEAD    # every commit on this branch, even if a secret was later deleted
python3 scripts/secret-scan.py --self-test                  # proves each rule flags a known-bad sample
```

## A false positive

Review it first. If it is genuinely safe, add `secret-scan: allow` to that line (for example in a comment).

## Limits

- **The hook can be skipped** (`git commit --no-verify`) and is not installed automatically on a fresh clone. The CI job is the
  backstop, and making it a required status check makes it binding.
- **Pattern matching is not perfect.** It can miss unusual secret formats and cannot recognise a secret it has no rule for.
  It complements GitHub's own secret scanning and push protection, which are also enabled; it does not replace them.
- **If a real secret was ever pushed, rotate it.** Deleting it from the repository is not enough, because it stays in history
  and may already have been copied.
- Your commit author email is already visible in every commit and cannot be hidden retroactively.
