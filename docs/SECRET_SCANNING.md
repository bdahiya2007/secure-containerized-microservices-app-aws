# Secret scanning

Nothing secret, confidential or personal may be committed, because this repository is public. One scanner,
[scripts/secret-scan.py](../scripts/secret-scan.py), enforces that in three places so the rules cannot drift apart, and GitHub's own secret
scanning adds a second, independent layer. The policy in one page is in [SECURITY.md](../SECURITY.md); this page is the detail.

| Layer | When | Scope |
|---|---|---|
| **Pre-commit hook** (`.githooks/pre-commit`) | Every `git commit` on your machine | What is staged |
| **CI job** "Scan for secrets and sensitive data" (`validate.yml`, a required check) | Every pull request | Every tracked file, and every line added by every commit in the PR |
| **By hand** | Any time | `--staged`, `--all-tracked` or `--range BASE..HEAD` |
| **GitHub secret scanning with push protection** (repository setting) | Every push | Known provider token formats; refuses the push before the secret is stored |

Only content that is committed (or about to be) is scanned by the project's own scanner. Git-ignored local files, such as `demo.auto.tfvars`,
`terraform.tfvars`, `backend.hcl`, `TODO.md` or Terraform state, are not: they are kept out by `.gitignore` and by the file-name rule below.

## What it blocks

| Category | Examples |
|---|---|
| Credentials | AWS access keys and secret keys, private key blocks, GitHub and Slack tokens, JWTs, a password, secret or token assigned a literal value, Google OAuth secrets, client IDs, API keys and tokens |
| AWS identifiers | An account ID inside an ARN or in a resource name, deployed API, SSO and CloudFront hostnames, Cognito pool IDs and hosted domains |
| Personal data | Email addresses (except `example.com`, `example.org`, `example.net` and the `users.noreply.github.com` address), personal file paths such as `/home/<user>/` or `C:\Users\<user>` |
| Files that must never be committed | `*.tfstate`, `*.tfvars`, saved plans (`*.tfplan`, `tfplan`), `.env` and `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.ppk`, `id_rsa*`, `id_ed25519*`, `*credentials*`, `.terraformrc`, and the folders `.terraform/`, `.aws/` and `.ssh/` (`.terraform.lock.hcl` and `.env.example` are allowed, and their contents are still scanned) |
| Your own block list | Exact values you list, such as your account ID, your public IP address, your domain and your email |

**What it does not catch by itself.** There is no rule for a public IP address, a domain name or a bare 12-digit number outside an ARN: a real
address such as the owner's `/32` in `alb_ingress_cidr`, the real domain, or a hosted zone ID would pass. This project keeps those out by
convention (real values only in git-ignored files, placeholders such as `example.com` and `<account id>` everywhere else) and by listing them in
the private block list below. If you are new to the project, add them to that list first.

Use placeholders in docs and code: `<account id>`, `you@example.com`, `products.example.com`. That is why the real values live only in the
git-ignored `terraform/demo.auto.tfvars`, `terraform/region-b/terraform.tfvars` and `backend.hcl`.

## What `.gitignore` keeps out

`.gitignore` is the first barrier: the scanner's file-name rule is the second, so a file has to defeat both to be committed.

| Group | Patterns |
|---|---|
| Keys and credentials | `*.pem`, `*.key`, `*.ppk`, `*.p12`, `*.pfx`, `*credentials*`, `id_rsa*`, `id_ed25519*`, `.aws/`, `.ssh/`, `.env` and `.env.*` (but `.env.example` is committed) |
| Terraform | `*.tfstate` and `*.tfstate.*`, `*.tfvars` and `*.tfvars.json` (so `demo.auto.tfvars` and `terraform.tfvars`; `*.tfvars.example` is committed), saved plans (`*.tfplan`, `tfplan`), `backend.hcl` (it holds the state bucket name, which contains the account ID; `backend.hcl.example` is committed), `**/.terraform/*`, `override.tf` and its variants, `.terraformrc`, crash logs. The `.terraform.lock.hcl` files are committed on purpose |
| Generated files | `terraform/db-rotation.zip`, `*.zip`, `taskdef.json`, `revision.json`, `*.rendered.*`, `dist/`, `build/` |
| DR drill and scan output | `probe*.csv` (a probe file holds the load balancers' real IP addresses), `evidence*/`, `overrides.json`, `*.sarif` |
| Private working files | `TODO.md` (real names and addresses), `.claude/`, `scratch/`, `tmp/`, editor and OS files, logs and caches |

**Local files that exist and are ignored on a working machine:** `TODO.md`, `terraform/demo.auto.tfvars`, `terraform/region-b/terraform.tfvars`, both `backend.hcl` files, `terraform/bootstrap/terraform.tfstate` (the deploy role's **only** state, local, so back it up yourself), the `.terraform/` folders, `terraform/db-rotation.zip`, `node_modules/` and Python bytecode. Old local state for the main stack (`terraform/terraform.tfstate*`, left from before the move to S3 on 2026-10-31) is safe to delete once a plan shows no changes.

Check that nothing tracked matches an ignore rule with `git ls-files -ci --exclude-standard` (it prints nothing when all is well), and that a
new file type is ignored with `git check-ignore -v <path>`.

## Enable the hook (once per clone)

```bash
./scripts/install-hooks.sh        # sets git config core.hooksPath .githooks and runs the scanner's self-test
```

A blocked commit prints the rule, file and line with a **redacted** snippet, never the value itself. The hook is local: it can be skipped
(`git commit --no-verify`) or never enabled, which is why the pull request check re-runs the scan on every commit and every tracked file. The
check is required for `main`, and the rule applies to administrators too.

## Accepting a false positive

Add `secret-scan: allow` to the line. **The marker is honoured everywhere, including in CI**, so anyone who can open a pull request can add it to
a real secret and the scanner will skip that line. Treat every new marker as a review item: look for them in a diff with
`git diff main... | grep "secret-scan: allow"`. Branch protection and the single-owner model are what stop an abuse, not the scanner.

## Block your own values (kept out of the repo)

The built-in rules cannot know your account ID, public IP address, domain or email, and writing them in the repo would publish them. List them,
one per line, in `~/.config/secret-scan/literals` on your machine, and in the optional repository secret `SECRET_SCAN_LITERALS` for CI. Neither
is ever committed. Matches are reported as "a value from your private block list" without showing the value.

## The scanner and its tests

`python3 scripts/secret-scan.py --self-test` checks every rule against sample bad and good inputs, and also runs in CI before the scan. The
samples are built from pieces, so the test file does not trigger the rules it tests. A change to the scanner is a normal pull request and is
scanned like any other file, except that `scripts/secret-scan.py` itself is not (it contains the patterns).

The same scanner is used in the companion repositories. This copy has diverged slightly from `secure-serverless-api-aws` (it has no private-IP
rule because this project's VPC ranges, such as `10.0.0.0/16`, are documented on purpose, and it allows `.env.example`). Keep the shared rules in
step by hand when one changes.

## Other places that catch leaks

- **Trivy** scans the built image for embedded secrets on every pull request and weekly.
- **GitHub secret scanning and push protection** are on for the repository, and alerts (currently none open) are under Security.
- **Terraform write-only arguments** keep the database password out of state (`docs/Secrets.md`), and the app reads it from Secrets Manager at
  runtime, so no secret is in the image, the task definition or the environment.

## If a secret was ever committed

1. **Rotate it first.** Deleting it from history is not enough, because it may already be cloned or cached. For the database password run a
   rotation (`aws secretsmanager rotate-secret`); for an AWS key deactivate and replace it.
2. Remove it from the repository in a pull request, and check the GitHub Security tab for an alert about it.
3. Decide whether history needs rewriting. For a public repository the old commit and any closed pull-request refs stay reachable until GitHub
   purges them, so rotation, not rewriting, is the real fix.
4. Add a rule or a block-list entry so the same kind of value is caught next time.

## Known limits

- The hook can be skipped; CI is the real backstop.
- `secret-scan: allow` is honoured in CI.
- No public-IP, domain or hosted-zone rule: those depend on the private block list.
- The scan covers file contents and added lines, not commit messages, branch names, PR titles or descriptions, or issue text.
- It has not been run over the full history as a one-off with a second tool.
