#!/bin/bash
# One-shot setup for the lab 05 stack:
#   - sanity-checks the host (docker compose v2, curl, WSL quirks)
#   - installs the repo's git hooks (skip-worktree for the machine-local
#     Ignition config file) and a diff driver that hides volatile resource.json
#     metadata; volatile-only churn is undone with
#     scripts/clean-ignition-resource-churn.sh
#   - ensures .env is in place
#   - generates a unique API key per gateway into .env (nothing key-related
#     is committed or baked into an image); local gets its token via the bind
#     mount, test/production get theirs installed into the container
#     (scripts/install-api-token.sh)
#   - brings up the stack (three Ignition gateways + shared TimescaleDB)
#   - waits for ALL THREE gateways to become RUNNING
#   - triggers an initial projects + config scan against the LOCAL gateway.
#     Test and production start on the BASE image (empty gateways) by design — they get
#     replaced by the image deploy.yml builds / release.yml promotes.
#
# Re-run safely — every step is idempotent.
#
# Env knobs:
#   CI=1                            run non-interactively (never prompt/sudo)
#   LAB_SKIP_PREFLIGHT=1            skip the host permission checks entirely
#   LAB_ALLOW_DRVFS=1               allow running from /mnt/c (not recommended)
#   LAB_ASSUME_YES=1                auto-answer preflight prompts with yes
#   NO_COLOR=1                      disable ANSI colors

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=preflight.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight.sh"
cd "$PROJECT_ROOT"

# ---- Host preflight (WSL/permissions) ------------------------------------
# Verifies the repo is not on /mnt/c, refuses a sudo'd run, reclaims any
# root-owned leftovers, and exports LAB_GID for docker-compose.yaml.
lab_preflight

# ---- prerequisites --------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo -e "${RED}Error: '$1' is required but not installed.${NC}" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd git
require_cmd python3

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker Compose V2 plugin is required but not installed.${NC}"
    echo ""
    echo "You appear to have the standalone 'docker-compose' (V1), which is deprecated."
    echo ""
    echo "Install the Docker Compose V2 plugin:"
    echo "  - Docker Desktop (Windows/Mac): Update to the latest version"
    echo "  - Linux/WSL: sudo apt-get update && sudo apt-get install docker-compose-plugin"
    echo "  - Or see: https://docs.docker.com/compose/install/"
    exit 1
fi

echo -e "${GREEN}Mustry Academy — Lab 05 setup${NC}"
echo "================================"
echo ""
echo "This script initializes the development environment:"
echo "  - three Ignition 8.3 gateways:"
echo "      local  http://localhost:8088   (your authoring gateway, bind-mounted from the repo)"
echo "      test    http://localhost:8089   (runs the image deploy.yml builds on push to main)"
echo "      production   http://localhost:8090   (runs the image release.yml promotes on tag push)"
echo "  - one TimescaleDB on localhost:5432 hosting ignition_local_development / ignition_test / ignition_production"
echo ""


# ---- Git hooks ------------------------------------------------------------
install_git_hooks() {
    local repo_hooks_dir
    repo_hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)" || return 0
    local source_dir="$PROJECT_ROOT/scripts/git-hooks"
    [ -d "$source_dir" ] || return 0
    mkdir -p "$repo_hooks_dir"
    for hook in post-merge post-checkout post-rewrite; do
        local target="$repo_hooks_dir/$hook"
        ln -sf "$source_dir/$hook" "$target"
    done
    if [ -x "$source_dir/skip-worktree-ignition-resources" ]; then
        "$source_dir/skip-worktree-ignition-resources" || true
    fi
}

install_git_hooks

# ---- Git diff driver --------------------------------------------------------
# .gitattributes routes resource.json through this textconv normalizer so
# volatile Designer metadata (timestamps, signatures) never shows up in diffs.
configure_git_diff_drivers() {
    git config diff.ignition-resource.textconv "$PROJECT_ROOT/scripts/git-diff/normalize-ignition-resource-json.py"
}

configure_git_diff_drivers

# ---- .env -----------------------------------------------------------------
ensure_env_file() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi
    if [ ! -f "$PROJECT_ROOT/.env.example" ]; then
        echo -e "${RED}Error: neither .env nor .env.example found.${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}.env not found — copying from .env.example.${NC}"
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "${YELLOW}Edit .env to set gateway passwords; the IGNITION_API_KEY_* values${NC}"
    echo -e "${YELLOW}are generated automatically in the next step.${NC}"
    echo ""
}

ensure_env_file
# Record LAB_GID in the fresh .env so a later manual `docker compose up -d`
# (the image deploy in this lab!) keeps the gateway in your group without the
# setup.sh shell's export. See pf_persist_lab_gid in scripts/preflight.sh.
pf_persist_lab_gid

# ---- Per-gateway API keys (never committed, never baked) -------------------
# Generates a unique key per gateway into .env and writes the LOCAL gateway's
# hash-only token resource into the bind-mounted services/config BEFORE first
# boot (token resources are only read at boot). Test/production run images
# and get their token docker-cp'ed in after boot (install-api-token.sh, in
# the repair step below and after every deploy-image.sh run).
"$SCRIPT_DIR/generate-api-keys.sh"
# The token resource written just above is born AFTER lab_preflight's chmod
# pass, which "only touches dirs that exist" — so on a fresh clone it gets the
# student's umask (typically 022: no group write) and the LOCAL gateway
# (uid 2003, writing via the student's group) cannot rewrite it. Re-apply the
# bind-mount permissions now that it exists.
pf_prepare_bind_mounts

# ---- Stale-volume detection (identity/volume desync) -----------------------
# The LOCAL gateway's internal identity (user-source/default, identity-
# provider/default) lives in its bind-mounted config tree (services/config),
# but the "already commissioned" marker lives in its data VOLUME. Docker
# Compose reuses volumes by project name, so a fresh clone sitting next to a
# volume from an earlier stack boots a gateway that skips commissioning yet
# has no identity on disk: the web UI dies with "Identity provider not found:
# default". Detect that desync and recreate the container + volume so
# commissioning runs again on this boot. (Test/production have no data volumes —
# they re-commission from the image + env vars on every deploy by design.)
compose_project_name() {
    docker compose config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true
}

reset_desynced_local() {
    local project vol identity_dir
    project="$(compose_project_name)"
    if [ -z "$project" ]; then
        project="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    fi
    identity_dir="$PROJECT_ROOT/services/config/resources/core/ignition/user-source/default"
    vol="${project}_ignition-local-data"
    if [ ! -d "$identity_dir" ] && docker volume inspect "$vol" >/dev/null 2>&1; then
        echo -e "${YELLOW}local gateway: data volume '$vol' exists but its config tree has no internal identity${NC}"
        echo "  (fresh clone next to an old stack?) — recreating it so commissioning runs again."
        docker compose rm -sf ignition-local >/dev/null 2>&1 || true
        docker volume rm "$vol" >/dev/null
    fi
}

reset_desynced_local

# ---- Local first-boot: stash security-properties during commissioning -----
# On the very first boot of the LOCAL gateway, auto-commissioning has to
# guarantee an admin login exists. If it finds a security-properties file but
# no matching user source (the repo tracks the policy file; the per-gateway
# user-source/default is gitignored), it plays safe and creates a temp_N
# identity, then rewrites security-properties to point at it — permanent git
# noise AND an auth profile no other gateway has. If it finds NO
# security-properties, it creates the `default` user source + identity
# provider, exactly like test/production do on every image deploy. So: move the
# committed file aside for the first boot, then put it back (it names
# systemAuthProfile=default, which now exists, and carries the APIToken scan
# permissions) and restart local.
SECPROPS_DIR="$PROJECT_ROOT/services/config/resources/core/ignition/security-properties"
SECPROPS_STASH=""
stash_secprops_for_commissioning() {
    local usersource_dir="$PROJECT_ROOT/services/config/resources/core/ignition/user-source/default"
    # If a previous interrupted run left the file stashed away, recover the
    # committed version from git before deciding anything.
    if [ ! -d "$SECPROPS_DIR" ]; then
        git -C "$PROJECT_ROOT" checkout -- "$SECPROPS_DIR" 2>/dev/null || true
    fi
    if [ -d "$usersource_dir" ] || [ ! -d "$SECPROPS_DIR" ]; then
        return 0   # not a first boot (or nothing to stash)
    fi
    SECPROPS_STASH="$(mktemp -d)"
    mv "$SECPROPS_DIR" "$SECPROPS_STASH/security-properties"
    echo -e "${YELLOW}First boot of the local gateway: letting commissioning create the${NC}"
    echo -e "${YELLOW}default identity before restoring the committed security-properties.${NC}"
}

restore_secprops_after_commissioning() {
    [ -n "$SECPROPS_STASH" ] || return 0
    rm -rf "$SECPROPS_DIR"   # drop the commissioning-written version
    mv "$SECPROPS_STASH/security-properties" "$SECPROPS_DIR"
    rmdir "$SECPROPS_STASH" 2>/dev/null || true
    SECPROPS_STASH=""
    echo -e "${GREEN}Restored the committed security-properties; restarting local to load it...${NC}"
    docker restart "$(gateway_container local)" >/dev/null
    wait_for_gateway local
}

stash_secprops_for_commissioning

# ---- Start the stack ------------------------------------------------------
existing_id="$(docker compose ps -q ignition-local 2>/dev/null || true)"
if [ -n "$existing_id" ]; then
    echo -e "${YELLOW}Stack already running — 'docker compose up -d' will be a no-op or apply changes.${NC}"
fi
echo -e "${GREEN}Starting the stack...${NC}"
docker compose up -d
echo ""
docker compose ps
echo ""

# ---- Wait for the gateways ------------------------------------------------
wait_for_gateway() {
    local gateway="$1"
    local url
    url="$(gateway_url "$gateway")"
    echo -e "${GREEN}Waiting for $gateway gateway at $url to become RUNNING...${NC}"
    local attempts=0
    local max_attempts=120  # ~4 minutes per gateway; cold start is slow
    while [ $attempts -lt $max_attempts ]; do
        local state
        state="$(curl -fsS "${url}/StatusPing" 2>/dev/null | grep -o RUNNING || true)"
        if [ "$state" = "RUNNING" ]; then
            echo ""
            echo -e "${GREEN}  $gateway gateway RUNNING${NC}"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 2
        echo -n "."
    done
    echo ""
    local container
    container="$(gateway_container "$gateway")"
    echo -e "${RED}Error: $gateway gateway did not reach RUNNING within $((max_attempts * 2))s.${NC}" >&2
    echo "  Check logs:  docker logs --tail 200 $container" >&2
    return 1
}

# Wait for each in series. Could be parallelized; sequential output is
# easier to scan and the total cold-start time is dominated by the JVM
# startup of each gateway anyway.
for gw in "${LAB_GATEWAYS[@]}"; do
    wait_for_gateway "$gw"
done

restore_secprops_after_commissioning

# ---- API-token repair (first boot only) -----------------------------------
# Each gateway is probed with ITS OWN generated key from .env. Two failure
# modes, both first-boot only for local (persistent volume), and once per
# container recreate for test/production:
#   401 = the gateway never LOADED a matching token. Local has the generated
#         token in its bind mount, so a restart loads it. Test/production
#         keep no host config tree — install the token into the container
#         (install-api-token.sh docker-cp's it in, grafts the permissions,
#         and restarts). deploy-image.sh does the same after every deploy.
#   403 = commissioning reset the read/write permissions in
#         security-properties; the key authenticates but every call is
#         Forbidden. Graft the APIToken permissions back and restart
#         (fix-gateway-api-perms.sh).
probe_scan_api() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
        -H "X-Ignition-API-Token: $(api_key_for "$1")" \
        "$(gateway_url "$1")/data/api/v1/scan/projects" || true
}

repair_api_perms() {
    local needs_fix=()
    local gw code
    for gw in "${LAB_GATEWAYS[@]}"; do
        [ -n "$(api_key_for "$gw")" ] || continue   # no key to probe with
        code="$(probe_scan_api "$gw")"
        case "$code" in
            403) needs_fix+=("$gw") ;;
            401)
                if [ "$gw" = "local" ]; then
                    echo -e "${YELLOW}API token not loaded yet on local — restarting it to load the generated token...${NC}"
                    docker restart "$(gateway_container local)" >/dev/null
                    wait_for_gateway local
                    code="$(probe_scan_api local)"
                    [ "$code" = "403" ] && needs_fix+=(local)
                else
                    echo -e "${YELLOW}API token not on $gw yet — installing it into the container...${NC}"
                    "$SCRIPT_DIR/install-api-token.sh" "$gw"
                fi
                ;;
        esac
    done
    [ ${#needs_fix[@]} -eq 0 ] && return 0
    echo -e "${YELLOW}First-boot commissioning reset the API permissions on: ${needs_fix[*]}${NC}"
    echo "Grafting the APIToken permissions back and restarting..."
    "$SCRIPT_DIR/fix-gateway-api-perms.sh" "${needs_fix[@]}"
}

repair_api_perms

# ---- Initial scan (local only) -------------------------------------------
# Local has projects on disk from the bind mount; test/production start empty by
# design (workflows will populate them).
initial_scan() {
    if [ ! -x "$SCRIPT_DIR/trigger-scan.sh" ]; then
        echo -e "${YELLOW}scripts/trigger-scan.sh missing or not executable, skipping initial scan.${NC}"
        return 0
    fi

    load_api_key_from_env local
    if is_placeholder_api_key; then
        echo -e "${YELLOW}No API key in .env yet — skipping initial scan.${NC}"
        echo "  scripts/generate-api-keys.sh should have created one; run it, then:"
        echo "    scripts/trigger-scan.sh local"
        return 0
    fi

    echo -e "${GREEN}Triggering initial scan on local gateway...${NC}"
    if ! "$SCRIPT_DIR/trigger-scan.sh" local; then
        echo ""
        echo -e "${YELLOW}Initial scan failed (likely the key lacks scan permission).${NC}"
        echo "  Fix the role for the API key, then run:  scripts/trigger-scan.sh local"
    fi
}

initial_scan

# ---- Done -----------------------------------------------------------------
# Pull the actual values from .env so the output matches reality.
ACTUAL_LOCAL_USER="$(env_value GATEWAY_ADMIN_USERNAME_LOCAL)"
ACTUAL_LOCAL_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_LOCAL)"
ACTUAL_TEST_USER="$(env_value GATEWAY_ADMIN_USERNAME_TEST)"
ACTUAL_TEST_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_TEST)"
ACTUAL_PRODUCTION_USER="$(env_value GATEWAY_ADMIN_USERNAME_PRODUCTION)"
ACTUAL_PRODUCTION_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_PRODUCTION)"
ACTUAL_PG_USER="$(env_value POSTGRES_USER)"
ACTUAL_PG_PASS="$(env_value POSTGRES_PASSWORD)"

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
printf "Gateways:\n"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "local"  "http://localhost:8088"  "${ACTUAL_LOCAL_USER:-admin}"  "${ACTUAL_LOCAL_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "test"    "http://localhost:8089"  "${ACTUAL_TEST_USER:-admin}"    "${ACTUAL_TEST_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "production"   "http://localhost:8090"  "${ACTUAL_PRODUCTION_USER:-admin}"   "${ACTUAL_PRODUCTION_PASS:-(see .env)}"
echo ""
echo "TimescaleDB:"
echo "  Host: localhost  Port: 5432"
echo "  Databases: ignition_local_development, ignition_test, ignition_production"
echo "  Username: ${ACTUAL_PG_USER:-ignition}  Password: ${ACTUAL_PG_PASS:-(see .env)}"
echo ""
echo "API keys (unique to this clone, generated into .env — never committed,"
echo "never baked into an image):"
echo "  IGNITION_API_KEY_LOCAL / _TEST / _PRODUCTION — one per gateway;"
echo "  scripts/trigger-scan.sh picks the right one from its argument"
echo "  (local | test | production). Deploys to"
echo "  test/production reinstall that gateway's token into the fresh container"
echo "  automatically (scripts/install-api-token.sh)."
echo 
echo "Useful commands:"
echo "  docker compose ps                              # check container state"
echo "  docker logs -f lab05-ignition-local            # tail local gateway logs"
echo "  scripts/trigger-scan.sh                        # rescan local (file-based loop)"
echo "  scripts/build-image.sh                         # build the gateway image"
echo "  scripts/deploy-image.sh test <image>            # recreate test from an image"
echo "  scripts/teardown.sh                            # stop the stack"
echo "  scripts/teardown.sh --volumes                  # stop and wipe persistent data"
