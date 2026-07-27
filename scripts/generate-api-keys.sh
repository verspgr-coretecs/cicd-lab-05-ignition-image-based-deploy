#!/usr/bin/env bash
# generate-api-keys.sh — provision one Ignition scan-API key PER GATEWAY,
# without ever putting a secret in git or baking one into a published image.
#
# Earlier versions of this lab shipped a pre-provisioned token: the hash was
# committed under services/config (and baked into every image pushed to GHCR)
# and the full key sat in .env.example — working credentials in every clone
# AND every published image. Exactly what a CI/CD course should not do.
# Instead, every clone now generates its own keys.
#
# For each gateway (local / test / production) this script ensures .env has a
# real IGNITION_API_KEY_<GW>: if the line is empty, missing, or a
# placeholder, it generates `cicd:<base64url(32 random bytes)>`.
#
# Only the LOCAL gateway gets its token resource written to disk here — the
# gateway stores only the SHA-256 hash of the secret, and local bind-mounts
# services/config, so the resource lands at
#   services/config/resources/core/ignition/api-token/cicd/   (gitignored AND
# .dockerignore'd: it must never enter a commit or an image build context).
#
# Test/production run images and are recreated on every deploy, so they have no
# host config tree: their token is derived from the SAME .env key and copied
# into the running container by scripts/install-api-token.sh (setup.sh and
# deploy-image.sh call it automatically).
#
# Idempotent: an existing key in .env is kept, and the local resource is only
# (re)written when its hash does not match the key. .env is the single source
# of truth — every token is re-derivable from it at any time.
#
# Finally, the same keys are mirrored into .flint/tokens/<env>-api.json for
# the Flint VS Code extension (dotenv format, gitignored per-clone), so the
# extension's resource tree, search and script debugger work from a fresh
# clone with no gateway UI detour.
#
# Usage:
#   scripts/generate-api-keys.sh          # normally invoked by setup.sh

set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v python3 >/dev/null || { echo -e "${RED}python3 is required${NC}" >&2; exit 1; }

if [ ! -f "$PROJECT_ROOT/.env" ]; then
  echo -e "${RED}No .env found — run scripts/setup.sh (it creates .env first).${NC}" >&2
  exit 1
fi

python3 - "$PROJECT_ROOT" <<'PYEOF'
import base64, hashlib, json, os, re, secrets, sys, time, uuid

root = sys.argv[1]
env_path = os.path.join(root, ".env")
with open(env_path) as f:
    env_text = f.read()

TOKEN_NAME = "cicd"
# env-var suffix -> config tree to write the token resource into, or None
# when the gateway has no host config tree (image-based test/production get
# their token docker-cp'ed in by scripts/install-api-token.sh instead).
GATEWAYS = {
    "LOCAL":      "services/config",
    "TEST":       None,
    "PRODUCTION": None,
}


def is_placeholder(value):
    return not value or "replace-me" in value or ":" not in value


def token_hash(key):
    # Ignition 8.3 api-token: hash = base64url_nopad(sha256(secret bytes)),
    # where the key is "<name>:<base64url_nopad(secret bytes)>".
    secret_b64 = key.split(":", 1)[1]
    raw = base64.urlsafe_b64decode(secret_b64 + "=" * (-len(secret_b64) % 4))
    return base64.urlsafe_b64encode(hashlib.sha256(raw).digest()).rstrip(b"=").decode()


def token_config(thash):
    # Same profile shape as the token the gateway UI creates: the APIToken
    # levels are what the security-properties scan permissions check for.
    api_children = [{"children": [], "name": n} for n in ("Access", "Read", "Write")]
    return {
        "profile": {
            "secureChannelRequired": False,
            "securityLevels": [{
                "children": [
                    {"children": [{"children": [], "name": "Administrator"}],
                     "name": "Roles"},
                    {"children": api_children, "name": "APIToken"},
                ],
                "description": "Represents a user who has been authenticated by the system.",
                "name": "Authenticated",
            }],
            "timestamp": int(time.time() * 1000),
            "type": "basic-token",
        },
        "settings": {"tokenHash": thash},
    }


env_changed = False
for gw, config_dir in GATEWAYS.items():
    var = f"IGNITION_API_KEY_{gw}"
    m = re.search(rf"^[ \t]*{var}=(.*)$", env_text, re.M)
    value = m.group(1).strip().strip("\"'") if m else ""

    if is_placeholder(value):
        secret = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
        value = f"{TOKEN_NAME}:{secret}"
        line = f"{var}={value}"
        if m:
            env_text = env_text[:m.start()] + line + env_text[m.end():]
        else:
            env_text = env_text + ("" if env_text.endswith("\n") else "\n") + line + "\n"
        env_changed = True
        print(f"  {gw.lower()}: generated a new API key into .env ({var})")

    if config_dir is None:
        continue

    name = value.split(":", 1)[0]
    thash = token_hash(value)
    res_dir = os.path.join(root, config_dir, "resources/core/ignition/api-token", name)
    config_path = os.path.join(res_dir, "config.json")

    current = None
    if os.path.isfile(config_path):
        try:
            with open(config_path) as f:
                current = json.load(f)["settings"]["tokenHash"]
        except (ValueError, KeyError):
            pass
    if current == thash:
        continue

    os.makedirs(res_dir, exist_ok=True)
    with open(config_path, "w") as f:
        json.dump(token_config(thash), f, indent=2)
        f.write("\n")
    with open(os.path.join(res_dir, "resource.json"), "w") as f:
        json.dump({
            "scope": "A", "description": "", "version": 1,
            "restricted": False, "overridable": True,
            "files": ["config.json"],
            "attributes": {"uuid": str(uuid.uuid4()), "enabled": True},
        }, f, indent=2)
        f.write("\n")
    print(f"  {gw.lower()}: wrote api-token resource -> {config_dir}/resources/core/ignition/api-token/{name}/")

if env_changed:
    with open(env_path, "w") as f:
        f.write(env_text)

# Flint (the Ignition VS Code extension) reads the same gateway API key from
# its own token file, one per environment in flint.config.json. Derive them
# from the keys above so a fresh clone gets a working extension — resource
# tree, search and the script debugger — straight out of scripts/setup.sh,
# with no gateway UI detour. Format is dotenv, not JSON, despite the
# extension's .json path. .flint/tokens/* is gitignored: these are live
# credentials and are per-clone, exactly like .env.
flint_dir = os.path.join(root, ".flint", "tokens")
for gw in GATEWAYS:
    m = re.search(rf"^[ \t]*IGNITION_API_KEY_{gw}=(.*)$", env_text, re.M)
    if not m:
        continue
    key = m.group(1).strip().strip("\"'")
    if is_placeholder(key):
        continue
    dest = os.path.join(flint_dir, f"{gw.lower()}-api.json")
    desired = f"ignition_token={key}\n"
    if os.path.isfile(dest) and open(dest).read() == desired:
        continue
    os.makedirs(flint_dir, exist_ok=True)
    with open(dest, "w") as f:
        f.write(desired)
    print(f"  {gw.lower()}: wrote Flint token -> .flint/tokens/{gw.lower()}-api.json")
PYEOF
