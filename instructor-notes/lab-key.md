# Lab 05 — instructor answer key

> **Don't read this before attempting the You-do.** For part 1 the value is in building the image yourself and watching the layer cache behave. For part 2 the interesting content is the digest-equality proof and the rollback, not the click-path.

---

# Part 1 — Build the gateway image

## What success looks like

By the end of part 1, the participant has:

1. Built the gateway image with `scripts/build-image.sh`, tagged `:sha-<short>` + `:local`.
2. Run the image with **no bind mounts** and seen `example-project` load at the test port — the self-contained proof.
3. Baked a project change (the `description` in `project.json`) into the image and confirmed it via `docker run … cat project.json` (no running gateway).
4. Explained the Dockerfile's layer order as a cache strategy.
5. Extended `.dockerignore` and kept `scripts/validate.sh` green.
6. Traced an image back to its commit via the `org.opencontainers.image.revision` label.

If #2 or #3 is missing, push them to finish — those two are the whole "the image *is* the artifact" lesson.

## The four COPY lines, annotated

```dockerfile
COPY third-party-modules/  /third-party-modules/                       # big, rare → top
COPY services/modules.json /usr/local/bin/ignition/data/modules.json   # module enablement
COPY services/config/      /usr/local/bin/ignition/data/config/        # gateway config
COPY projects/             /usr/local/bin/ignition/data/projects/      # daily churn → bottom
```

Things to highlight in the grade:

- **modules.json is in the image.** This is the single biggest contrast with Lab 04. A participant who can articulate "a scan can't enable a module, but baking it + recreating the container can" has the core idea.
- **Layer order.** If they reordered `projects/` to the top "because it's the most important," that's the teachable miss — importance isn't the axis, *volatility* is. Most-volatile last keeps rebuilds cheap.
- **Paths match Lab 04's `docker cp` targets.** `data/projects` and `data/config` are the same dirs the file-based deploy wrote into. The difference is *when* (build time vs deploy time) and *mutability* (frozen layer vs live copy).

## The `.dockerignore`, annotated

The line that matters most is `.env`. Grade for whether they understand *why*: a careless future `COPY . .`, or even a misconfigured tool, would otherwise bake credentials into a published, pullable artifact. `.dockerignore` is the backstop, not just a speed optimization. The speed/cleanliness reasons (`.git/`, `docs/`) are secondary.

## Common stumbles

- **"`git status` says `security-properties` changed and there's a `temp` user source I never made."** A commissioning run created it: the gateway commissions whenever its data volume is gone (wiped by hand, `compose down -v`, a Docker Desktop cleanup), and if identity files from the previous volume are still in the config tree it plays safe, invents a `temp_N` profile and rewrites the tracked `security-properties` to point at it — stripping the APIToken scan permissions on the way. `scripts/setup.sh` now prevents it (it asks the *volume*, not the config tree, whether the gateway will commission, and clears stale identity first) and repairs an existing one on the next run; `validate.sh` and `ci.yml` fail the build if a `temp_N` profile reaches a commit, because deploying an auth policy that names a profile only one machine has is a lockout. Manual fix: `git checkout -- services/config/resources/core/ignition/security-properties/` and `rm -rf services/config/resources/core/ignition/{user-source,identity-provider}/temp*`.

- **"My change isn't in the image."** They edited a file but it's matched by `.dockerignore`, or they edited under a path the Dockerfile doesn't `COPY`. Have them run `docker run --rm --entrypoint find <image> /usr/local/bin/ignition/data` and look (the `--entrypoint` is required — the IA image treats trailing args as gateway arguments otherwise).
- **"Every build rebuilds everything."** They're editing a top layer's input (e.g. `third-party-modules/`), or Docker's cache was cleared. Show `CACHED` vs not in the build output and tie it to which file they touched.
- **"It won't build — not found in build context."** A `COPY` source typo or a `.dockerignore` pattern that's too broad. The error names the path; read it.
- **"The standalone `docker run` won't come up."** Missing `-e ACCEPT_IGNITION_EULA=Y`, or they didn't wait for the JVM. It's slower than they expect.
- **Confusing the build context with the image.** The context is what's *sent* to the daemon; the image is what the `COPY`s *select* from it. `.dockerignore` shrinks the former; the Dockerfile selects the latter.

## Failure-case discussion

Breaking the build on purpose is the cheap, high-value lesson: **image-based moves failures left.** A bad `COPY` path, malformed JSON the build depends on, or a missing module file fails the *build* — on a free hosted runner, before any gateway is touched. In Lab 04 the same class of mistake shipped files onto a live gateway and you found out at scan time (or worse, at runtime). Tie this to `ci.yml`'s no-push build smoke test: the PR fails, not production.

## Stretch notes

- **`docker history --no-trunc`.** Largest layer is almost always the base image, then third-party modules. The `projects/` layer is tiny. Good prompt: "if projects were 500 MB of assets, would you still bake them, or mount them / pull at runtime?" There's no single right answer — it's the trade-off that matters.
- **Multi-stage.** Right answer: you don't need it here (IA image is the runtime, we only copy files). You'd add a builder stage to compile a custom module or run tooling you don't want in the shipped image.

## Bridge to part 2

The image exists locally. Part 2 deploys it by recreating the container; the repo's CI workflows extend the same flow through a registry. Foreshadow the two questions that flow answers:

1. *Where does the image go, and who's allowed to push/pull it?* (GHCR + `GITHUB_TOKEN`.)
2. *How do you ship the same image you tested to production?* (Build-once / promote-many — re-tag, don't rebuild.)

---

# Part 2 — Deploy the image

## What success looks like

This lab runs **entirely locally — no self-hosted runner, no fork, no GitHub account required.** Builds are local (`scripts/build-image.sh`) and deploys are manual (`IGNITION_TEST_IMAGE=<tag> docker compose up -d ignition-test`). The CI workflows exist and build/promote images, but they deliberately have **no deploy job**: the last mile is the student's to type. Only the optional stretch touches GitHub at all.

By the end of part 2, the participant has:

1. Deployed **their own built image** to test (:8089), proven with `docker inspect -f '{{.Config.Image}}'`.
2. Shipped a view change end-to-end: edit → commit → rebuild → redeploy → visible on test.
3. **Two immutable `:sha` tags** in their local image store, one per build, each traceable to its commit.
4. **Rolled test back** to the older tag by re-running the same command with the older name, and verified the old view is live.
5. Confirmed historian data in TimescaleDB survived every deploy — and can say why (it was never in the container).
6. Can name the two steps a production pipeline adds between build and run (**push + pull**), and why we skipped them today.

If #4 is missing, push them to do it — rollback-as-a-rename is the conceptual centerpiece. #6 is the second-most important: it's the bridge to the stretch and to Lab 06.

## The five-step pattern, walked through

Use on the board if they need a re-walk:

1. **Build** — `docker build` bakes projects/config/modules.
2. **Tag** — `:sha-<short>` (immutable) + `:test` (moving).
3. **Push** — to a registry (GHCR, with `GITHUB_TOKEN`).
4. **Pull** — on the machine that owns the target gateway.
5. **Run** — `docker compose up -d ignition-test` recreates the container from it.

**Today they do 1, 2, and 5 — steps 3 and 4 are skipped entirely** because the image never leaves the laptop. Say that out loud: it's why deploy is a one-liner here. In the stretch, CI does 1–3 and they do 4–5 by hand. In Lab 06/07 a runner does 4–5 for them.

Contrast explicitly with Lab 04's checkout → prune → ship → scan → verify. The artifact changed (files → image) and the gateway lifecycle changed (mutate-in-place → replace).

## The workflow structure, annotated

`deploy.yml` is **build-only** — one job, no deploy:

```yaml
jobs:
  build:                    # runs-on: ubuntu-latest  (FREE, portable)
    permissions: { packages: write }   # GHCR push via GITHUB_TOKEN
    # login → buildx → build-push-action (push: true) → cache to gha
    # → final step prints the image ref to $GITHUB_STEP_SUMMARY
  # (no deploy job — the last mile is manual in this lab)
```

Things to highlight in the grade:

- **The build/deploy split.** The single biggest operational difference from Lab 04. The build no longer has to happen next to the gateway, so it moves to free hosted minutes; only the last-mile recreate needs a privileged machine. A participant who can explain *why* you'd want that split (cost, blast radius, the privileged box does less) gets the lesson.
- **Why there's no deploy job here.** Ask them: *what would that job need that a hosted runner can't have?* Answer: access to the Docker daemon running the gateway. That's the whole reason self-hosted runners exist, and it's what Lab 06/07 set up. Having typed the pull+recreate by hand, they know exactly what that runner would be doing.
- **Deploy the immutable `:sha-…`, not `:test`.** Moving tags drift; the `:sha` is the rollback point. Part 2.3 depends on them having written one down.
- **`permissions: packages: write`.** Least privilege for the registry, no PAT.
- **`concurrency` + `cancel-in-progress: false`.** Don't cancel a deploy mid-recreate; queue the next one.
- **`environment:`.** Even empty, it buys per-stage deploy history and the place to bolt on required reviewers for production.

`release.yml` is the same shape but the first job is **promote, not build** — `imagetools create` re-tags the tested image. Make sure they notice it does **not** rebuild.

### GitHub flow framing (why we promote `:test`, not a rebuild)

This lab is **GitHub flow**: a merge to `main` → test gateway, a `vX.Y.Z` tag on `main` → production gateway. The subtlety worth teaching: `release.yml` does **not** rebuild from the tagged commit — it promotes the **`:test` image** (what the test gateway is running). That's the honest definition of a release: *ship what the test gateway validated*. Tagging is the freeze point: you tag when the test gateway is where you want production to be. If a participant asks "why not just rebuild from the tag?" — that breaks build-once/promote-many: a rebuild could pull a newer base layer and ship bytes the test gateway never tested.

## The digest-equality proof

This is the money moment. After a release:

```bash
docker inspect -f '{{.Image}}' lab05-ignition-test
docker inspect -f '{{.Image}}' lab05-ignition-production
```

Same `sha256:…`. If a participant shrugs, ask: *"What would it take for these to differ, and why would that scare you?"* Answer: a rebuild for production could pull a newer base layer or a non-deterministic dependency — production would run something the test gateway never tested. Build-once/promote-many makes that impossible by construction.

> Why `{{.Image}}` and not `{{ index .RepoDigests 0 }}`? `.RepoDigests` only exists on **image** objects — running it against a container name errors out. `.Image` on a **container** is the sha256 ID of the image it runs, which is exactly the equality we want, and it also works for locally-built images that have no registry digest.

## Rollback

The canonical image-based rollback: *re-promote a previous tag.* `release.yml`'s `workflow_dispatch` takes a `tag` input; running it with `v0.1.0` re-tags that **existing** image to `:production` and recreates production. No rebuild, no `git revert`, no history surgery.

Have them compare to Lab 04, where rolling production back meant re-copying old files and re-scanning — more steps, more partial-state risk, and nothing immutable to point at. The grade question: *"How many irreversible steps are in each rollback path?"* Image-based: zero (you're pointing at an artifact that already exists).

## Common stumbles

> Most of the GitHub-related stumbles below only apply to the **optional stretch** — the core lab never leaves the laptop.

- **"The workflow finished but nothing deployed."** Expected, and worth pre-empting: there is no deploy job. CI builds and prints a tag; deploying it is manual. If someone waits for test to change on its own, they'll wait forever.
- **#1 by far (stretch) — nothing happens after merge.** Forks ship with **Actions disabled**; the participant never enabled them (Actions tab → "I understand my workflows…"). No CI, no build, no push. Check this first whenever "the workflow didn't run."
- **"Can I even push? It's your registry."** Reassure: the build publishes to *their own* `ghcr.io/<their-fork-owner>/…` (the workflow derives the namespace from `github.repository_owner`), never to Mustry's. Nothing in the lab pushes to a registry they don't own. Good moment to show them the package appearing under *their* fork → Packages.
- **403 pushing, org-owned fork.** If their fork is under a GitHub org, *Settings → Actions → General → Workflow permissions* must be **read and write**, and org Packages must be enabled. Personal forks are fine by default. (Plain `permissions: packages: write` is already in the workflow.)
- **401 pulling the CI-built image (stretch).** GHCR packages are private by default, so pulling one by hand needs a one-off `docker login ghcr.io` (username = GitHub user, password = a token with `read:packages`). Or flip the package public in its settings.
- **`manifest unknown` on release.** No `:test` image exists yet — they tagged a release before ever shipping anything to test. Fix: push to `main` so `deploy.yml` publishes `:test`, then tag. (On a rollback dispatch, it means that version was never released.) See TROUBLESHOOTING.
- **Duplicate stack appears.** Compose project name mismatch — confirm the `name: cicd-lab05` field is set at the top of `docker-compose.yaml`. Without it, the directory name becomes the project and compose spins up a parallel set.
- **"I deployed but test didn't change."** Either `IGNITION_TEST_IMAGE` wasn't actually set on the command (a common shell-quoting slip), or they deployed `:test`/`:local` (moving) and Docker reused a cached digest. Inspect `{{.Config.Image}}` on the container — that settles it in one command.
- **Expecting a hot reload.** Someone edits a view and expects test to update without a deploy. That's the *local* gateway's job (file-based). Test/production only change when an image is deployed. This confusion is worth surfacing — it's exactly the file-vs-image boundary.

## Debrief talking points

- **Immutable vs moving tags.** Deploy `:sha-<short>`, navigate with `:test`/`:production`. A participant who'd `docker compose up` with `:test` pinned in production has a footgun — moving tags drift under you.
- **Atomicity.** Image recreate keeps the old container until the new one is ready, then swaps. Lab 04's `rm -rf` + `docker cp` had a partial-state window. Image-based deletes that failure mode.
- **What persists.** Historian → Timescale (survives). Everything in the image dies and is reborn each deploy. Push them to place user accounts / audit logs / alarm journal in that mental model — each is a "image vs volume vs database" decision in a real deployment.
- **Who is allowed to touch the gateway?** Today it was them, by hand. Automating that means giving some machine the Docker socket — and in production you wouldn't hand that out casually; you'd use a pull-based agent on the gateway host or an orchestrator. Good segue to Lab 06/07 and the multi-gateway story.

## Wrap-up — set up the next day
- Foreshadow multi-gateway: "You promoted one image to one production gateway. Next: the same image to *many* gateways, and how you coordinate that fan-out."
