#!/usr/bin/env bash
# Turns on the repository's git hooks (the secret-scan pre-commit check) for this clone.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
command -v python3 >/dev/null || { echo "python3 is required for the secret scan" >&2; exit 1; }
git config core.hooksPath .githooks
python3 scripts/secret-scan.py --self-test
echo "Pre-commit secret scan enabled (git config core.hooksPath = .githooks)."
echo "Optional: list values to block (account ID, email) in ~/.config/secret-scan/literals, one per line."
