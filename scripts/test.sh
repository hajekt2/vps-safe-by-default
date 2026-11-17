#!/usr/bin/env bash
# Local checks: syntax, lint, template parse, and --help. No host changes.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }

printf '\n1. Shell syntax\n'
for script in "$root"/scripts/*.sh; do
    if bash -n "$script"; then ok "bash -n $(basename "$script")"; else bad "bash -n $script"; fi
done

printf '\n2. ShellCheck\n'
if command -v shellcheck >/dev/null; then
    if shellcheck -x "$root"/scripts/harden.sh "$root"/scripts/verify.sh "$root"/scripts/test.sh; then
        ok "shellcheck clean"
    else
        bad "shellcheck reported findings"
    fi
else
    printf '  skip  shellcheck not installed\n'
fi

printf '\n3. Templates\n'
if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$root/cloud-init.yaml" 2>/dev/null; then
    ok "cloud-init.yaml parses"
else
    printf '  skip  PyYAML not installed\n'
fi
if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$root/templates/compose.yaml" 2>/dev/null; then
    ok "templates/compose.yaml parses"
else
    printf '  skip  PyYAML not installed\n'
fi

printf '\n4. Help paths\n'
for script in harden.sh verify.sh; do
    if "$root/scripts/$script" --help >/dev/null; then ok "$script --help"; else bad "$script --help"; fi
done

printf '\n5. No secrets or private identifiers\n'
if grep -rnE 'tskey-[A-Za-z0-9]{10,}|eyJ[A-Za-z0-9_-]{20,}' "$root" --include='*.md' --include='*.sh' --include='*.yaml'; then
    bad "a token-shaped string is committed"
else
    ok "no token-shaped strings"
fi

printf '\n'
if ((failures > 0)); then printf '%d check(s) failed\n\n' "$failures"; exit 1; fi
printf 'All local checks passed.\n\n'
