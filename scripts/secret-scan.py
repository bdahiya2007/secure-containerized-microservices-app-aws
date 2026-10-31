#!/usr/bin/env python3
"""Blocks secrets and sensitive data before they reach a public repository.

One scanner, used in three places so the rules never drift apart:
  * the git pre-commit hook (.githooks/pre-commit)      -> --staged
  * a CI job (planned, not yet added to this repository) -> --all-tracked and --range BASE..HEAD
  * by hand                                             -> any mode

Only content that is (or is about to be) committed is scanned, never git-ignored local files.
Matches are reported with the rule, file and line, and a REDACTED snippet, so a CI log never
re-leaks what it found. Put `secret-scan: allow` on a line to accept a reviewed false positive.

Optional local-only list of exact values to block (your account ID, email, ...), one per line, in
$SECRET_SCAN_LITERALS_FILE (default ~/.config/secret-scan/literals) and/or the SECRET_SCAN_LITERALS
environment variable (CI passes a repository secret). Those values must never be written in the repo.
"""
import argparse
import os
import re
import subprocess
import sys

ALLOW_MARKER = "secret-scan: allow"
SELF = "scripts/secret-scan.py"          # contains the patterns themselves, so its content is not scanned
EMAIL_ALLOWED_DOMAINS = ("example.com", "example.org", "example.net", "users.noreply.github.com")

RULES = [
    ("aws-access-key", "AWS access key ID",
     r"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[0-9A-Z]{16}\b"),
    ("aws-secret-key", "AWS secret key assignment",
     r"(?i)aws_?secret_?access_?key\s*[:=]\s*[\"']?[A-Za-z0-9/+=]{20,}"),
    ("private-key", "private key block",
     r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY"),
    ("github-token", "GitHub token",
     r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    ("slack-token", "Slack token", r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    ("google-oauth-secret", "Google OAuth client secret", r"\bGOCSPX-[A-Za-z0-9_-]{20,}"),
    ("google-oauth-client-id", "Google OAuth client ID",
     r"\b\d{8,}-[a-z0-9]{16,}\.apps\.googleusercontent\.com\b"),
    ("google-api-key", "Google API key", r"\bAIza[0-9A-Za-z_-]{35}\b"),
    ("google-oauth-token", "Google OAuth access or refresh token", r"\bya29\.[0-9A-Za-z_-]{20,}|\b1//[0-9A-Za-z_-]{30,}"),
    ("jwt", "JSON Web Token",
     r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    ("literal-secret", "password/secret/token assigned a literal value",
     r"""(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\b\s*[:=]\s*["']([^"'\s$\{\(<][^"'\s$\{\(]{7,})["']"""),
    ("aws-account-id", "AWS account ID inside an ARN",
     r"arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:\d{12}:"),
    ("account-id-suffix", "12-digit account ID in a resource name",
     r"[A-Za-z]-\d{12}(?!\d)|(?i:account[_-]?id)\W{0,5}\d{12}(?!\d)"),
    ("resource-hostname", "deployed API / SSO / CDN hostname",
     r"\b[a-z0-9]{10}\.execute-api\.[a-z0-9-]+\.amazonaws\.com\b|\bd-[0-9a-f]{10}\.awsapps\.com\b|\b[a-z0-9]{13,14}\.cloudfront\.net\b"),
    ("cognito-pool-id", "Cognito user pool ID", r"\b[a-z]{2}-[a-z]+-\d_[A-Za-z0-9]{9}\b"),
    ("cognito-hosted-domain", "Cognito hosted sign-in domain (a live resource name)",
     r"\b[a-z0-9][a-z0-9-]{0,61}[a-z0-9]\.auth\.[a-z0-9-]+\.amazoncognito\.com\b"),
    ("personal-path", "personal file path",
     r"/home/(?!runner\b)[a-z][a-z0-9_-]+/|\b[A-Za-z]:\\Users\\[A-Za-z0-9._-]+"),
]
COMPILED = [(rid, desc, re.compile(rx)) for rid, desc, rx in RULES]
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})")

FORBIDDEN_NAMES = [
    "*.tfstate", "*.tfstate.*", "*.tfvars", "*.tfvars.json", "tfplan", "*.tfplan", ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx",
    "*.ppk", "id_rsa*", "id_ed25519*", "*credentials*", ".terraformrc", "terraform.rc",
]
FORBIDDEN_DIRS = (".terraform/", ".aws/", ".ssh/")


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def mask(text):
    return f"{text[:3]}...({len(text)} chars)" if len(text) > 3 else "***"


def forbidden_name(path):
    base = os.path.basename(path)
    # The lock file pins provider versions, and .env.example holds placeholders only (.gitignore allows both).
    # Their contents are still scanned like any other file.
    if base in (".terraform.lock.hcl", ".env.example"):
        return None
    if any(path.startswith(d) or f"/{d}" in f"/{path}" for d in FORBIDDEN_DIRS):
        return "forbidden directory"
    import fnmatch
    if any(fnmatch.fnmatch(base, p) for p in FORBIDDEN_NAMES):
        return "forbidden file type (state, variables, key or credentials)"
    return None


def literals():
    values = [v for v in os.environ.get("SECRET_SCAN_LITERALS", "").splitlines()]
    path = os.environ.get("SECRET_SCAN_LITERALS_FILE", os.path.expanduser("~/.config/secret-scan/literals"))
    if os.path.isfile(path):
        values += open(path).read().splitlines()
    return [v.strip() for v in values if v.strip() and not v.strip().startswith("#")]


def scan_line(text, lits):
    """Yield (rule id, description, redacted snippet) for every finding in one line."""
    if ALLOW_MARKER in text:
        return
    for rid, desc, rx in COMPILED:
        for m in rx.finditer(text):
            yield rid, desc, mask(m.group(0))
    for m in EMAIL.finditer(text):
        domain = m.group(1).lower()
        local = m.group(0).split("@")[0].lower()
        if domain in EMAIL_ALLOWED_DOMAINS or (domain == "github.com" and local == "git"):
            continue
        yield "email", "email address (personal data)", mask(m.group(0))
    low = text.lower()
    for lit in lits:
        if lit.lower() in low:
            yield "local-literal", "a value from your private block list", "(value not shown)"


def added_lines(diff):
    """Yield (path, line number, text) for added lines of a `-U0` unified diff, and (path, 0, None) per file."""
    path, lineno = None, 0
    for raw in diff.splitlines():
        if raw.startswith("diff --git "):
            m = re.match(r"diff --git a/.* b/(.*)$", raw)
            if m:
                yield m.group(1), 0, None
        elif raw.startswith("+++ "):
            p = raw[4:]
            path = None if p == "/dev/null" else (p[2:] if p.startswith("b/") else p)
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            lineno = int(m.group(1)) if m else 0
        elif raw.startswith("+") and path:
            yield path, lineno, raw[1:]
            lineno += 1


def tracked_lines():
    for path in run("git", "ls-files").splitlines():
        yield path, 0, None
        try:
            if os.path.getsize(path) > 1_000_000:
                continue
            data = open(path, "rb").read()
        except OSError:
            continue
        if b"\0" in data:
            continue
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            yield path, n, line


def scan(items):
    lits, findings, seen = literals(), [], set()
    for path, n, text in items:
        if (path, "name") not in seen:
            seen.add((path, "name"))
            why = forbidden_name(path)
            if why:
                findings.append((path, 0, "forbidden-file", why, os.path.basename(path)))
        if text is None or path == SELF:
            continue
        for rid, desc, snip in scan_line(text, lits):
            findings.append((path, n, rid, desc, snip))
    return findings


def report(findings, where):
    if not findings:
        print(f"secret-scan: OK, nothing sensitive found in {where}.")
        return 0
    print(f"secret-scan: BLOCKED, {len(findings)} finding(s) in {where}:\n")
    for path, n, rid, desc, snip in findings:
        loc = f"{path}:{n}" if n else path
        print(f"  [{rid}] {loc}\n      {desc}: {snip}")
    print("\nRemove or replace the value (use a placeholder such as ACCOUNT_ID or you@example.com).")
    print(f"If a hit is a reviewed false positive, add '{ALLOW_MARKER}' to that line.")
    print("If a real secret was ever pushed, rotate it: deleting it from history is not enough.")
    return 1


def self_test():
    j = "".join
    bad = {
        "aws-access-key": j(["AKIA", "ABCDEFGHIJKLMNOP"]),
        "aws-secret-key": j(["aws_secret_", "access_key = ", "A" * 40]),
        "private-key": j(["-----BEGIN RSA ", "PRIVATE KEY-----"]),
        "github-token": j(["ghp_", "a" * 36]),
        "slack-token": j(["xox", "b-", "1234567890-abcdef"]),
        "jwt": j(["eyJ", "a" * 12, ".eyJ", "b" * 12, ".", "c" * 12]),
        "google-oauth-secret": j(["GOCSPX", "-", "a" * 24]),
        "google-oauth-client-id": j(["123456789012", "-", "abcdefghijklmnopqrst", ".apps.googleusercontent", ".com"]),
        "google-api-key": j(["AI", "za", "A" * 35]),
        "google-oauth-token": j(["ya", "29.", "a" * 30]),
        "cognito-hosted-domain": j(["my-orders", ".auth.", "us-east-1", ".amazoncognito.com"]),
        "literal-secret": j(['pass', 'word = "', 'Hunter2Hunter2', '"']),
        "aws-account-id": j(["arn:aws:iam::", "123456789012", ":role/x"]),
        "account-id-suffix": j(["my-bucket-", "123456789012"]),
        "resource-hostname": j(["abcde12345", ".execute-api.us-east-1.amazonaws.com"]),
        "cognito-pool-id": j(["us-east-1_", "Abcdefghi"]),
        "personal-path": j(["/home/", "alice/project"]),
        "email": j(["someone", "@", "gmail.com"]),
    }
    good = [
        "arn:aws:iam::ACCOUNT_ID:role/save-order-role", "contact you@example.com", "git@github.com:org/repo.git",
        "password = var.db_password", 'PASSWORD="$(openssl rand -hex 12)"', "token: ${{ secrets.TOKEN }}",
        "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "Table Orders on-demand", "1,281 ms cold start", "vpc_cidr = 10.0.0.0/16",
        "/home/runner/work/repo", "version = \"6.67.0\"",
        "<client id>.apps.googleusercontent.com", "https://<prefix>.auth.<region>.amazoncognito.com/oauth2/idpresponse",
        "https://<prefix>.auth.us-east-1.amazoncognito.com/oauth2/idpresponse", "GOCSPX-... (a Google client secret)", "x = 1.2.3.4", "secret-scan: allow " + j(["AKIA", "ABCDEFGHIJKLMNOP"]),
    ]
    names_bad = ["tfplan", "x/prod.tfplan", "terraform.tfstate", "a/b/prod.tfvars", ".env", "k.pem", "terraform/.terraform/providers/x", "aws-credentials.json"]
    names_good = [".terraform.lock.hcl", "product-service/.env.example", "terraform/environments/dev/main.tf", "README.md"]
    failures = []
    for rid, sample in bad.items():
        hit = {r for r, _, _ in scan_line(sample, [])}
        if rid not in hit:
            failures.append(f"rule '{rid}' did not flag its sample")
    for sample in good:
        hit = [r for r, _, _ in scan_line(sample, [])]
        if hit:
            failures.append(f"false positive {hit} on a known-good sample")
    for name in names_bad:
        if not forbidden_name(name):
            failures.append(f"file name not flagged: {name}")
    for name in names_good:
        if forbidden_name(name):
            failures.append(f"file name wrongly flagged: {name}")
    if scan_line("host = " + j(["secret", "-value-1"]), ["secret-value-1"]).__next__()[0] != "local-literal":
        failures.append("local literal list not honoured")
    if failures:
        print("secret-scan self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"secret-scan self-test OK: {len(bad)} rules and {len(names_bad)} file-name checks flag their samples; "
          f"{len(good)} safe samples pass.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--staged", action="store_true", help="scan what is staged for commit (pre-commit hook)")
    g.add_argument("--all-tracked", action="store_true", help="scan every tracked file")
    g.add_argument("--range", metavar="BASE..HEAD", help="scan every line added by the commits in a range")
    g.add_argument("--self-test", action="store_true", help="check that the rules flag known-bad samples")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.staged:
        diff = run("git", "diff", "--cached", "-U0", "--no-color", "--diff-filter=ACMR")
        return report(scan(added_lines(diff)), "the staged changes")
    if a.range:
        diff = run("git", "log", "-p", "-U0", "--no-color", "--format=", a.range)
        return report(scan(added_lines(diff)), f"commits {a.range}")
    return report(scan(tracked_lines()), "all tracked files")


if __name__ == "__main__":
    sys.exit(main())
