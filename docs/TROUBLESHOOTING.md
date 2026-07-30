# Troubleshooting

Quick fixes for the things that bite people during the lab. Work top to bottom; most issues
are one of the first three.

## The stack won't start / `scripts/setup.sh` fails

- **Docker isn't running or isn't Compose v2.** `docker compose version` must work (note the space —
  not `docker-compose`). Start Docker Desktop and re-run `scripts/setup.sh` (it's idempotent).
- **Not enough RAM.** Three gateways at 1 GB each + TimescaleDB need **≥ 8 GB free**.
  Raise Docker's memory or bump the per-gateway limit in [`docker-compose.yaml`](../docker-compose.yaml).
- **Port already in use.** 8088/8089/8090 (gateways) or 5432 (TimescaleDB). Stop the other process or
  change the host port mappings.

## A gateway never reaches RUNNING

- Give it time — a cold JVM start is 60–120 s per gateway, and an **image-based** boot re-commissions
  the gateway, so test/production can take a little longer than `local`.
- Check logs (use `docker logs` with the container name, not `docker compose logs`):
  ```bash
  docker logs --tail 200 lab05-ignition-test     # or -local / -production
  ```
- **Trial expired.** Each gateway runs in 2-hour trial mode. Reset via *Gateway → Config → Licensing →
  Reset Trial*. Note: recreating test/production from a fresh image resets their trial clock too.

## `docker build` / `scripts/build-image.sh` fails

- **`invalid reference format` with `ghcr.io/<your-github-user>/…` in the tag.** A stale `.env` still
  has the `.env.example` placeholder `IGNITION_IMAGE_REPO=ghcr.io/<your-github-user>/…`; the literal
  `<`/`>` are illegal in a Docker tag. `scripts/lib.sh` now ignores that placeholder and falls back to
  the registry-free local name `cicd-lab-05-ignition`, so a fresh `.env` builds fine. If you hit this on
  an old `.env`, just **comment out the `IGNITION_IMAGE_REPO=` line** — the local scripts need no registry.
- **"… not found in build context."** A `COPY` source path is wrong, or the path is excluded by
  [`.dockerignore`](../.dockerignore). Check the four `COPY` lines in the [`Dockerfile`](../Dockerfile)
  against what's actually on disk.
- **Context is huge / build is slow.** Something big is in the context. `du -sh .git` is the usual
  culprit — confirm `.git/` is in `.dockerignore`. Build with `--progress=plain` to see the transfer size.
- **Image builds but is missing a file.** It's almost always `.dockerignore` excluding something you
  meant to bake. Verify with `docker run --rm --entrypoint find <image> /usr/local/bin/ignition/data/projects`
  (the `--entrypoint` is required — the IA image otherwise treats trailing args as gateway arguments).

## Gateway FAULTs: "unable to create resource dir … /.resources"

The baked files are owned by a user the gateway cannot write as. The gateway runs as its own
`ignition` user (uid 2003) and must create runtime directories under `data/config/` at boot; a
plain `COPY` in a Dockerfile bakes files as **root**, so that fails.

The fix belongs in the build, not the run: every `COPY` in this lab's `Dockerfile` uses
`--chown=2003:0`. If you hit this after editing the Dockerfile, check you did not drop a `--chown`.
It's a useful reminder that **file ownership is part of what an image carries** — get it right at
build time and the container needs no special privileges at run time.

Do **not** work around it with `--user root`. That reintroduces the problem this course spent Lab 02
onwards avoiding: a root gateway writes root-owned files into your bind mounts, and you end up
needing `sudo` to edit your own project files. Full working stand-alone command is in
[`exercises/lab.md`](../exercises/lab.md) and printed by `scripts/build-image.sh`.

## Gateway stuck in `RUNNING / COMMISSIONING` (stand-alone run)

A bare `docker run` is missing the commissioning env vars, so the gateway waits on the setup wizard.
Add `-e IGNITION_EDITION=standard` and `-e GATEWAY_ADMIN_USERNAME=admin` (plus `ACCEPT_IGNITION_EULA=Y`
and `GATEWAY_ADMIN_PASSWORD`). The compose stack supplies all of these already, so deploys via
`deploy.yml` / `scripts/deploy-image.sh` don't hit this — it's only a stand-alone-run gotcha.

## GHCR push/pull fails (401 / 403 / denied)

The images publish to **your own fork's** GHCR namespace (`ghcr.io/<your-fork-owner>/…`), so this is
never about lacking access to *Mustry's* registry. A 403/401 almost always traces back to a GitHub
setting on your fork:

- **Workflow never ran at all.** Forks ship with Actions **disabled**. Open your fork's *Actions* tab
  and click "I understand my workflows, go ahead and enable them." Nothing builds or pushes until you do.
- **403 on push, org-owned fork.** If your fork lives under a GitHub **organization**, check
  *Settings → Actions → General → Workflow permissions* = **Read and write**, and that
  *Settings → … → Packages* aren't disabled for the org. Personal forks are read-write by default.
- **`denied: installation not allowed to Create organization package`.** Same org policy as above, or
  the org blocks package creation — push under a **personal** fork instead.
- **403 even with `packages: write`.** The workflow already requests it (in `deploy.yml` / `release.yml`);
  if you copied a job and dropped the `permissions:` block, add `packages: write` back.
- **401 on pull from the deploy job.** The deploy job must `docker login ghcr.io` with `GITHUB_TOKEN`
  before `docker pull` — confirm the *Log in to GHCR* step is present and ran.
- **Wrong namespace / `invalid reference format`.** GHCR paths must be lowercase. CI lowercases the owner
  automatically; the local `scripts/lib.sh` also lowercases and ignores the `.env.example` placeholder.
  If you hand-edited an image name, check for capitals or stray `<…>`.
- **Pulling locally (outside CI).** A private package needs `docker login ghcr.io` with a PAT that has
  `read:packages`. Or make the package public in its settings. (You don't need this for the lab — the
  local `build-image.sh`/`deploy-image.sh` flow uses local images and never touches GHCR.)

## `manifest unknown` when releasing

`release.yml` promotes the **`:test`** image (what the test gateway is running). If no `:test` image exists yet, the
re-tag fails with `manifest unknown`.

- **New release (tag push):** nothing has ever been shipped to test. Push a change to **`main`** so
  `deploy.yml` builds and publishes `:test` first, then tag the release.
- **Rollback (manual dispatch):** the version you asked to re-promote was never released — there's no
  `:vX.Y.Z` image for it. Use a version that actually shipped to production before.

## `no matching manifest for linux/arm64/v8` on pull (Apple Silicon)

Your `docker pull` of a CI-built image fails with `no matching manifest for linux/arm64/v8`.
Cause: the **build** ran on GitHub's `ubuntu-latest` (amd64) and produced an **amd64-only** image,
but your laptop is Apple Silicon (**arm64**), so the pull finds no matching architecture.

Fixed by building **multi-arch**: `deploy.yml`'s build job uses `docker/setup-qemu-action` and
`platforms: linux/amd64,linux/arm64`, so the pushed image runs natively on both. (Cheap here — the
Dockerfile is COPY-only, so there's nothing to emulate.)

If you still see it: the existing `:test` image in GHCR is the **old amd64-only** one. Trigger a fresh
build (push any gateway-content change to `main`) so a multi-arch `:test` overwrites it, then the
pull works cleanly. Confirm the published image is multi-arch with:
```bash
docker buildx imagetools inspect ghcr.io/<your-fork-owner>/cicd-lab-05-ignition:test
# should list both linux/amd64 and linux/arm64
```

## The deploy ran but my change isn't visible

- **Right gateway?** `local` = :8088 (your authoring gateway, file-based), `test` = :8089, `production` = :8090.
- **Which image is it running?**
  ```bash
  docker inspect -f '{{.Config.Image}}' lab05-ignition-test
  ```
  If it still shows `inductiveautomation/ignition:8.3.8`, the deploy didn't recreate it — the
  `IGNITION_TEST_IMAGE` override wasn't set. Re-run the deploy, or locally:
  `scripts/deploy-image.sh test <image>`.
- **Stale moving tag.** If you deployed `:test` by name and it didn't change, remember moving tags can
  point at an old digest on a host that already cached them. Deploy the immutable `:sha-<short>` tag.

## test/production stuck on the base image (empty gateway)

That's the **default** until the first deploy — `IGNITION_TEST_IMAGE` / `IGNITION_PRODUCTION_IMAGE` are unset,
so compose falls back to the base Ignition image. Run `deploy.yml` (push to `main`) / `release.yml`
(tag on `main`), or locally `scripts/build-image.sh && scripts/deploy-image.sh test cicd-lab-05-ignition:local`.

## The workflow finished but nothing deployed

Expected. This lab runs **no self-hosted runner**, so the workflows build and push images but never
touch a gateway. Deploying is manual: open the workflow run's summary, copy the image name it
printed, and point the gateway at it yourself:

```bash
docker pull ghcr.io/<your-fork-owner>/cicd-lab-05-ignition:sha-<short>
IGNITION_TEST_IMAGE=ghcr.io/<your-fork-owner>/cicd-lab-05-ignition:sha-<short> \
  docker compose up -d ignition-test
```

## A duplicate stack appears when running compose

If a parallel set of containers shows up, the Compose **project name** didn't match. This lab pins it
with `name: cicd-lab05` at the top of `docker-compose.yaml` — confirm that line is present and
unchanged.

## `git status` shows lots of `resource.json` changes

Ignition rewrites the `resource.json` manifests on every interaction, usually touching nothing
but volatile metadata (modification timestamp, actor, signature). That churn is **meant to be
visible** — real edits must show up in git — and it's undone, not hidden:

```bash
scripts/clean-ignition-resource-churn.sh          # dry run: lists volatile-only files
scripts/clean-ignition-resource-churn.sh --apply  # restores them from HEAD
```

Junk-only rewrites are reverted whether or not you already staged them. Files with real content
changes are never touched by the script.
`git diff` already hides the volatile metadata via a textconv driver wired by `scripts/setup.sh`;
re-run it if diffs still show timestamp/signature noise. Only the machine-local
`local-system-properties/config.json` stays `skip-worktree` (the hooks re-apply it).

## Validate before you push

```bash
scripts/validate.sh      # JSON + .dockerignore + hadolint + actionlint — mirrors CI
scripts/build-image.sh   # confirm the image actually builds
```

Still stuck? The instructor answer key ([lab-key.md](../instructor-notes/lab-key.md)) has deeper
failure-mode walkthroughs.


## Why resource.json keeps changing on its own

See [`resource-json-hygiene.html`](./resource-json-hygiene.html) for the full picture: what the junk fields are, the difference between hiding them and reverting them, and why an empty `git diff` does not mean the file on disk is clean.
