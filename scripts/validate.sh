#!/bin/bash
# validate.sh — local mirror of .github/workflows/ci.yml.
#
# Run this before opening a PR to catch the cheap stuff the CI workflow checks,
# without waiting for a runner:
#   1. Every *.json under projects/ and services/ parses.
#   2. .dockerignore excludes the lab/secret paths it should.
#   3. hadolint passes on the Dockerfile (only if hadolint is installed).
#   4. security-properties doesn't name a throwaway temp_N identity.
#   5. actionlint passes on .github/workflows/ (only if actionlint is installed).
#
# Exits non-zero if any check fails. No Ignition needed; Docker only if you want
# the optional build smoke test (CI always does it — see ci.yml).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$PROJECT_ROOT" || exit 1

rc=0

# 1. JSON validity sweep -------------------------------------------------------
echo "→ JSON validity sweep (projects/, services/)"
json_fail=0
while IFS= read -r f; do
  if ! python3 -m json.tool "$f" > /dev/null 2>&1; then
    echo -e "  ${RED}invalid JSON:${NC} $f"
    json_fail=1
  fi
done < <(find projects services -type f -name '*.json' 2>/dev/null)
if [ "$json_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — all JSON parses"
else
  rc=1
fi

# 2. .dockerignore sanity ------------------------------------------------------
# The build context must not carry secrets or lab tooling into the image. We
# don't reimplement Docker's matcher — we just confirm the must-exclude paths
# are present as patterns.
echo "→ .dockerignore excludes secrets + lab tooling"
if [ -f .dockerignore ]; then
  di_fail=0
  for must in ".env" ".git/" "scripts/" "docs/" "exercises/"; do
    if ! grep -qxF "$must" .dockerignore; then
      echo -e "  ${RED}missing pattern:${NC} $must"
      di_fail=1
    fi
  done
  if [ "$di_fail" -eq 0 ]; then
    echo -e "  ${GREEN}ok${NC} — required exclusions present"
  else
    rc=1
  fi
else
  echo -e "  ${RED}no .dockerignore${NC} — the build context would carry everything"
  rc=1
fi

# 3. hadolint on the Dockerfile (optional) -------------------------------------
echo "→ hadolint (Dockerfile)"
if command -v hadolint > /dev/null 2>&1; then
  if hadolint Dockerfile; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — hadolint not installed (CI runs it; see https://github.com/hadolint/hadolint)"
fi

# 4. identity policy -----------------------------------------------------------
# security-properties is tracked, so whatever it names has to exist on every
# gateway that reads it. Commissioning rewrites it to a throwaway `temp_N`
# profile when it runs with identity files that outlived their data volume
# (scripts/setup.sh heals that) — and a temp profile exists on exactly one
# gateway. Cheap check, because the failure mode is a locked-out gateway.
echo "→ identity policy (security-properties names a deployable profile)"
secprops="services/config/resources/core/ignition/security-properties/config.json"
if [ -f "$secprops" ]; then
  bad_profile="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(" ".join(sorted({v for k,v in d.items()
                       if k in ("systemAuthProfile","systemIdentityProvider")
                       and str(v).startswith("temp")})))' "$secprops" 2>/dev/null || true)"
  if [ -n "$bad_profile" ]; then
    echo -e "  ${RED}security-properties points at a throwaway identity:${NC} $bad_profile"
    echo "  A commissioning run rewrote it. Restore it and drop the temp identity:"
    echo "    git checkout -- $secprops"
    echo "    rm -rf services/config/resources/core/ignition/{user-source,identity-provider}/temp*"
    echo "  (or just re-run scripts/setup.sh, which now repairs this)"
    rc=1
  else
    echo -e "  ${GREEN}ok${NC} — no throwaway identity in the deploy payload"
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — $secprops not found"
fi

# 5. actionlint (optional) -----------------------------------------------------
echo "→ actionlint (.github/workflows/)"
if command -v actionlint > /dev/null 2>&1; then
  if actionlint -color; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — actionlint not installed (CI runs it; install from https://github.com/rhysd/actionlint to check locally)"
fi

echo ""
if [ "$rc" -eq 0 ]; then
  echo -e "${GREEN}validate.sh: all checks passed${NC}"
else
  echo -e "${RED}validate.sh: one or more checks failed${NC}"
fi
exit "$rc"
