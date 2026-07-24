# Dockerfile anatomy — cheat sheet

Reference reading for part 1 of the lab. What the gateway image is made of, where each piece lands, and how to keep builds fast and traceable.

## What goes in the image

The [`Dockerfile`](../Dockerfile) bakes the *deployable state* of a gateway on top of the official Ignition base image:

| Build input | Lands at | Why it's in the image |
|---|---|---|
| `third-party-modules/*.modl` | `/third-party-modules/` | The gateway loads them via `-Dignition.gateway.externalModulesFolder`. Baking them = the module binaries ship with the artifact. |
| `services/modules.json` | `data/modules.json` | Which modules turn on at boot. **A scan can't apply this — only a restart can.** That's the Lab 04 gap image-based closes. |
| `services/config/` | `data/config/` | Gateway-level config (DB connections, tag providers). Scanned at startup. The scan-API token is deliberately NOT baked — a published image must never carry credentials; deploys reinstall it into the container (`scripts/install-api-token.sh`). |
| `projects/` | `data/projects/` | Project content (Perspective views, scripts, tags). Scanned at startup. |

Everything else in the repo — docs, scripts, `.github/`, `.env` — is kept out by [`.dockerignore`](../.dockerignore). So is anything that belongs to **one** gateway rather than the artifact: the internal identity (`user-source/default/` holds an admin password hash — baking it would ship one gateway's login to every gateway running the image), per-instance keystores/UUIDs (`config/local/`, `config/resources/local/`), and `security-properties` (it names the internal user source, which isn't in the image — commissioning creates a fresh `default` identity from the container's `GATEWAY_ADMIN_*` env vars instead).

## The base image

```dockerfile
ARG IGNITION_VERSION=8.3.8
FROM inductiveautomation/ignition:${IGNITION_VERSION}
```

- **Pin it.** An immutable-artifact philosophy is undermined by a floating `:latest` base — two builds a week apart could differ in ways you didn't choose. Bump the pin deliberately and let CI rebuild.
- The base image already defines the entrypoint (the gateway launcher), `EXPOSE 8088`, and a healthcheck. We inherit all of it — there's nothing to override for a baked-state gateway.
- Runtime knobs (admin password, EULA acceptance, module license/cert acceptance, `GATEWAY_RESTORE_DISABLED`) stay as **environment variables** in `docker-compose.yaml`, not baked into the image. Config that varies per environment doesn't belong in a shared artifact.

## Layer order is a cache strategy

Each `COPY` is its own layer. Docker caches a layer keyed on its inputs and reuses it on rebuild if nothing changed. So order from **least- to most-frequently-changed**:

```dockerfile
COPY third-party-modules/  ...   # big, rarely changes  → top (rebuilt least often)
COPY services/modules.json ...
COPY services/config/      ...
COPY projects/             ...   # changes daily        → bottom (rebuilt most often)
```

Editing a Perspective view busts only the bottom layer and anything below it. If you put `projects/` at the top, every view tweak would also re-copy the (much larger) modules layer. Same files, slower builds.

> A busted layer busts **all layers after it**. That's why "most volatile last" works: the volatile thing has nothing expensive beneath it to invalidate.

## Tagging strategy

One image, several names:

| Tag | Kind | Set by | Use |
|---|---|---|---|
| `:sha-<short>` | **Immutable** | build | The thing you actually deploy. A SHA tag always points at one specific build. |
| `:test` | Moving | build | "Whatever's latest on test." Convenient pointer, never deploy *by this name* (it moves under you). |
| `:vX.Y.Z` | **Immutable** | promote | A released version. Re-tag of the tested `:sha-…`, no rebuild. |
| `:production` | Moving | promote | "Whatever's live in production." Same caveat as `:test`. |

Rule of thumb: **deploy immutable tags, navigate with moving tags.** `deploy.yml` recreates the gateway from `:sha-<short>`, not `:test`, precisely so the running container pins to one build.

## Provenance labels

```dockerfile
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="..."
```

CI passes `--build-arg GIT_SHA=$(git rev-parse --short HEAD)`. Read it back from any image or running container:

```bash
docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' <image>
```

That's how you answer "what commit is production actually running?" months later.

## Startup behaviour

On first boot the container has the baked `data/projects` and `data/config` but no internal gateway database yet, so the IA entrypoint **commissions** the gateway: it applies the admin credentials from the env vars and scans the baked content. With `GATEWAY_RESTORE_DISABLED=true` it won't try to restore a backup. Net effect: a fresh container comes up already serving your project — no manual scan, no `docker cp`.

Because test/production have **no persistent data volume** (see `docker-compose.yaml`), every deploy re-commissions from the image. That's the immutable model: the container is disposable; durable data lives in TimescaleDB.

## Build context and `.dockerignore`

The **build context** is the tarball Docker sends the daemon before running the Dockerfile. `.dockerignore` trims it:

- **Speed** — `.git/`, `docs/`, `exercises/` are excluded so they're not uploaded/checksummed every build.
- **Safety** — `.env` is excluded so secrets can't be baked into a published image, even if a future `COPY` is careless.
- **Cleanliness** — our `Dockerfile` only `COPY`s four paths, but `.dockerignore` is the backstop that keeps the context honest.

`scripts/validate.sh` and `ci.yml` both assert the must-exclude patterns (`.env`, `.git/`, `scripts/`, `docs/`, `exercises/`) are present.

## When you'd reach for more

This Dockerfile is deliberately single-stage — the IA image *is* the runtime, and we only copy files. You'd add a **builder stage** when you need tools that shouldn't ship in the final image:

- Compiling a custom Ignition module from source.
- Running a project/JSON linter or codegen that needs a toolchain.
- Fetching artifacts you then `COPY --from=builder` into the runtime stage.

For baking project + config + modules, single-stage is correct and simplest.
