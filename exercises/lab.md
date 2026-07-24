# Lab 05 — Build the gateway image & deploy it by replacing the container

**Duration:** ~3 hours, in two parts

1. **Build the gateway image** (~90 min) — bake project, config, **and modules** into immutable Docker layers, prove the image is self-contained, and learn to read the layer cache.
2. **Deploy the image** (~90 min) — deploy to the test gateway by recreating the container, ship a change end-to-end, and roll back by running the previous build's tag.

The second part deploys exactly the image you build in the first. Do them in order.

## Goal

You should leave this lab able to:

- Explain what an *image-based* gateway is: project, config, **and modules** baked into immutable Docker layers, versus files copied into a running gateway (Lab 04).
- Read the [`Dockerfile`](../Dockerfile) and say what each `COPY` puts where, and why the layer order is what it is.
- Read [`.dockerignore`](../.dockerignore) and explain why each pattern keeps the build context lean and secrets out of the image.
- Build the image, tag it `:sha-<short>` + `:local`, and run it **with no bind mounts** — proving the image is self-contained.
- Inspect the baked layers with `docker history` and trace a running container back to its commit.
- Deploy an image-based gateway by **recreating the container** from a new image — no `docker cp`, no scan call.
- Ship a change end-to-end by hand: edit → commit → rebuild → redeploy, and explain that this loop is exactly what a deploy pipeline automates.
- Roll a gateway back by **running the previous build's immutable tag**, and explain why versioned artifacts make that cheap.
- Say what survives a container-replace deploy (external DB data) and what does not (internal gateway state, trial clock, UI-made edits).

## Pre-flight

```bash
scripts/setup.sh    # idempotent — safe even if the stack is already up
```

You'll need Docker with Compose v2 and ~8 GB free RAM. No GitHub setup is needed — both parts run entirely on your machine. If you'd like to read ahead: [`docs/dockerfile-anatomy.md`](../docs/dockerfile-anatomy.md).

---

# Part 1 — Build the gateway image

**Timing:** 20 min demo · 20 min we-do · 10 min debrief

## We-do (20 min)

### The mental model

In Lab 04 the gateway was a long-lived, *mutable* thing: you copied files into its `data/` directory and asked it to scan. In image-based deploy the gateway is *immutable*: the deployable state is frozen into an image, and you deploy by replacing the whole container.

Both approaches deliver the same files to the same paths and achieve the same result. What changes is the trade-offs: file-based keeps the gateway alive (no restarts, fast inner loop) but you own the copy-and-delete logic; image-based gives you a frozen, versioned artifact with no copy scripts, but every deploy is a fresh gateway boot. This part is about experiencing the image side of that trade.

### Walk the Dockerfile

Open [`Dockerfile`](../Dockerfile). Four `COPY` lines bake the deployable state:

```dockerfile
FROM inductiveautomation/ignition:${IGNITION_VERSION}

COPY third-party-modules/  /third-party-modules/                       # large, rarely change
COPY services/modules.json /usr/local/bin/ignition/data/modules.json   # which modules turn on
COPY services/config/      /usr/local/bin/ignition/data/config/        # gateway config
COPY projects/             /usr/local/bin/ignition/data/projects/      # project content (changes most)
```

Two things to call out on the board:

1. **Where files land.** `data/projects/` and `data/config/` are the same paths Lab 04's `docker cp` targeted — Ignition scans them at startup. The difference is *when*: Lab 04 copied at deploy time into a running gateway; here they're present from the first boot.
2. **Layer order = cache strategy.** Docker caches each `COPY` layer keyed on its inputs. Order from least- to most-frequently-changed, so editing a Perspective view (bottom layer) doesn't bust the big modules layer above it. Rebuilds stay fast.

### Walk the .dockerignore

Open [`.dockerignore`](../.dockerignore). It's the image-based analogue of Lab 04's `.deployignore`: it controls what enters the **build context** — the tarball Docker hands the daemon before running the Dockerfile. Three reasons every excluded line matters:

- **Smaller/faster builds** — `docs/`, `exercises/`, `.git/` are megabytes Docker would otherwise upload and checksum on every build.
- **Cleaner image** — even though our `Dockerfile` only `COPY`s four things, a stray `COPY . .` in a future edit would drag in everything not ignored. Defence in depth.
- **No leaked secrets** — `.env` is excluded so credentials can never be baked into a published artifact. This is the line that matters most.

### Build it and run it standalone

```bash
scripts/build-image.sh          # builds, tags :sha-<short> and :local
docker history cicd-lab-05-ignition:local   # see the baked layers, newest on top
```

Now run the image **with no bind mounts** on a spare port — this is the proof that the image carries everything:

```bash
docker run -d --rm --name demo -p 9088:8088 \
  -e ACCEPT_IGNITION_EULA=Y \
  -e IGNITION_EDITION=standard \
  -e GATEWAY_ADMIN_USERNAME=admin \
  -e GATEWAY_ADMIN_PASSWORD=password \
  cicd-lab-05-ignition:local \
  -n demo -- -Dignition.allowunsignedmodules=true
docker logs -f demo
# wait ~30–60s for "Starting project: example-project" in the log,
# then open http://localhost:9088 → the example-project is there
```

No `./projects` mount, no scan call — the project showed up because it's *inside the image*. The `-d` runs it detached, so Ctrl-C only leaves the logs; stop the gateway with `docker stop demo` (the `--rm` cleans it up).

> **Why no `--user` flag?** The Dockerfile copies everything with `--chown=2003:0`, which is the image's own `ignition` user. Ownership is part of what you bake into an image: a plain `COPY` would make the baked files root-owned, and the gateway (which does not run as root) would FAULT on boot with `unable to create resource dir … /.resources` because it cannot create its runtime dirs under `config/`. Getting the ownership right at build time is why the container needs no special privileges at run time. The `IGNITION_EDITION` + `GATEWAY_ADMIN_USERNAME` vars let it auto-commission instead of waiting on the setup wizard.

## We do (20 min)

Together, build and dissect the image.

1. **Build with a real provenance stamp.** `scripts/build-image.sh` passes `--build-arg GIT_SHA=$(git rev-parse --short HEAD)`. Confirm it landed:
   ```bash
   docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
     cicd-lab-05-ignition:local
   ```
   That label is how you trace any running container back to the commit it was built from.

2. **Prove the layer cache.** Build once (done). First, a trap — `touch` a project file and rebuild:
   ```bash
   touch projects/example-project/project.json
   scripts/build-image.sh
   ```
   Every layer still says `CACHED`. Docker keys the `COPY` cache on a checksum of file *contents*; timestamps are invisible to it. Now make a real change and rebuild:
   ```bash
   printf '\n' >> projects/example-project/project.json   # any content change works
   scripts/build-image.sh
   ```
   The modules/config layers stay `CACHED`; only the `projects/` layer (and anything after it) rebuilds. Then drop a new dummy file into `third-party-modules/` and rebuild — notice *more* layers bust because that `COPY` sits higher in the Dockerfile. (A *new* file **is** a content change. Delete the dummy again afterwards, or it ships in every future build.)

3. **See what `.dockerignore` kept out.** The build already measured it: the first lines of the
   build output include `transferring context: ~60MB`. Compare with the folder on disk:
   ```bash
   du -sh .      # ≈ 130 MB — the build transferred only ~60
   du -sh .git   # the biggest excluded chunk
   ```
   Want the definitive list of what Docker *can* see? Dump the context with a throwaway probe
   build and list it:
   ```bash
   docker build -q -t ctx-probe -f- . <<'EOF'
   FROM busybox
   COPY . /ctx
   EOF
   docker run --rm ctx-probe find /ctx -maxdepth 1
   ```
   Only `projects/`, `services/`, and `third-party-modules/` — exactly what the Dockerfile COPYs.

4. **Explore the image, not the repo.** Open the image in Docker Desktop (*Images →
   `cicd-lab-05-ignition` → Files*) — or whatever image browser you prefer — and find all four
   things the Dockerfile COPYed. Three live under `/usr/local/bin/ignition/data/`: `projects/`,
   `config/` and `modules.json`; the fourth is `/third-party-modules` at the root. Note what's
   *not* there: `README.md`, `docs/`, `.env`. Prefer the CLI?
   The Ignition base image's entrypoint treats trailing args as *gateway* arguments, so override
   it with `--entrypoint`:
   ```bash
   docker run --rm --entrypoint find cicd-lab-05-ignition:local \
     /usr/local/bin/ignition/data/projects -maxdepth 2
   ```

## Definition of done (part 1)

You're finished with part 1 when:

- [ ] `scripts/build-image.sh` builds the image and tags it `:sha-<short>` + `:local`.
- [ ] You ran the image **with no bind mounts** and saw `example-project` load — proving it's self-contained.
- [ ] You can explain the Dockerfile's layer order in terms of cache busting.
- [ ] You can trace a built image back to its commit via the `revision` label.

## Stretch challenge `[OPTIONAL]`

- **Shrink the context.** Run `docker build` with `--progress=plain` and watch the "transferring context" size. Add more to `.dockerignore` and watch it drop.
- **`docker history --no-trunc`.** Find which layer is largest. Is it the base image, the modules, or your project? What would you do differently if the project were 500 MB of assets?
- **Multi-stage thinking.** Our Dockerfile is single-stage because the IA base image is already the runtime. When *would* you want a builder stage? (Hint: compiling a custom module from source, or running a project linter that needs tools you don't want in the final image.)

## Debrief (10 min)

- The image is immutable, but the gateway still writes runtime state (internal DB, logs) at `data/`. Where does that go in our test/production setup, and why is it safe to throw away on each deploy? (Hint: look at what's *not* a volume in `docker-compose.yaml`, and where historian data lives.)
- We pin `inductiveautomation/ignition:8.3.8`, not `:latest`. Why does an immutable-artifact philosophy demand a pinned base?
- Lab 04's `.deployignore` was read by a shell loop in the workflow; Lab 05's `.dockerignore` is read by the Docker daemon. What does moving that responsibility *into the tool* buy you?
- In part 2 this image gets deployed — and in a real pipeline it would go through a registry first. What's the one tag you'd never want to deploy to production by name, and why? (Foreshadow: moving vs. immutable tags.)

---

# Part 2 — Deploy the image locally by replacing the container

**Timing:** 15 min we-do · 40 min you-do · 10 min debrief

Everything in this part runs on your own machine, **and you type the deploy
commands yourself — no script**. In a real setup this part is automated by the
same GitHub Actions you built in Lab 04: a merge to `main` fires `deploy.yml`,
a tag fires `release.yml`; only the steps inside the jobs change (build + push +
pull + recreate instead of copy + scan). We skip GitHub today because a gateway
image is ~2 GB, and uploading that from a course laptop is not a good use of
your hour — the transport isn't the lesson. Every command below is a line the
workflow would run; your local Docker image store plays the role of the
registry.

## Pre-flight

Part 1 finished: you have a built image tagged `:sha-<short>` + `:local`, and
`scripts/setup.sh` has the stack up (local gateway :8088, test gateway :8089,
TimescaleDB).

## We-do (15 min)

Together, we deploy the part 1 image to the test gateway once:

1. **Before:** `docker inspect -f '{{.Config.Image}}' lab05-ignition-test` — test runs the plain base image (an empty gateway).
2. **Deploy — one command:**
   ```bash
   IGNITION_TEST_IMAGE=cicd-lab-05-ignition:local docker compose up -d ignition-test
   ```
   `docker-compose.yaml` interpolates `IGNITION_TEST_IMAGE` into the test service's
   `image:`; compose sees a new image and recreates the container.
3. **Wait for RUNNING:** `curl -s localhost:8089/StatusPing` until it prints
   RUNNING (a fresh-image boot re-commissions the gateway — give it a few minutes).
4. **Verify:** open http://localhost:8089/app/home/perspective/session-launcher and launch example-project — the baked project is live. No copy, no scan: the container was **replaced**. Inspect again — test now runs your image.
5. **What persisted:** historian data in TimescaleDB is untouched. The container died; the data that matters didn't live in it.

## You do (40 min)

### Part 2.1 — Deploy your image to test, command by command (10 min)

Repeat the we-do yourself, from your own build:

1. Confirm which image test runs (`docker inspect -f '{{.Config.Image}}' lab05-ignition-test`).
2. Deploy:
   ```bash
   IGNITION_TEST_IMAGE=cicd-lab-05-ignition:local docker compose up -d ignition-test
   ```
3. Poll `curl -s localhost:8089/StatusPing` until RUNNING, then verify at :8089 and inspect again.

### Part 2.2 — Ship a change end-to-end (15 min)

The full loop a pipeline automates. **Commit before you build** so each build
gets its own immutable `:sha` tag — that tag is your rollback point in Part 2.3.

1. Note the current build's `:sha-<short>` tag (`docker images cicd-lab-05-ignition`). Write it down.
2. Edit a Perspective view under `projects/example-project/…/views/` — make it visibly different (a title text works well).
3. Commit on a feature branch and merge to `main` (GitHub flow, like every lab):
   ```bash
   git checkout -b feature/tweak-view
   git add -A && git commit -m "Change overview title"
   git checkout main && git merge feature/tweak-view
   ```
4. Rebuild + redeploy:
   ```bash
   scripts/build-image.sh
   IGNITION_TEST_IMAGE=cicd-lab-05-ignition:local docker compose up -d ignition-test
   ```
5. Verify at :8089 — your change is live. `docker images` now shows **two** `:sha-…` tags: two deployable versions, both still on your machine.

### Part 2.3 — Roll back to the previous build (10 min)

1. Pretend Part 2.2's change broke something on test. You need the previous version back, now.
2. Deploy the **old** tag you wrote down in step 1 of Part 2.2 — the same command, older name:
   ```bash
   IGNITION_TEST_IMAGE=cicd-lab-05-ignition:sha-<the-old-short-sha> docker compose up -d ignition-test
   ```
3. Verify at :8089 — the view is back to its previous state.
4. Count the irreversible steps you just took. (Zero: both versions still exist, and you can flip between them all afternoon.)

## Definition of done (part 2)

- [ ] The test gateway (:8089) runs **your** image, proven with `docker inspect`.
- [ ] You shipped a view change end-to-end: edit → commit → rebuild → redeploy → visible on test.
- [ ] Your image store holds **two immutable `:sha` tags**, one per build, each traceable to its commit via the revision label.
- [ ] You rolled test back to the older tag and verified the old view is live again.
- [ ] You checked that historian data survived both deploys, and can say why.
- [ ] You can name the two steps a production pipeline adds between your build and your run (push + pull), and why we skipped them today.

> **Fresh gateway alert.** Each deploy gave test a brand-new gateway: new internal
> DB, new trial clock, gone are any UI-made edits. If that surprised you, good —
> that's the "fresh gateway" disadvantage from the teaching, experienced
> first-hand.

## Stretch challenge `[OPTIONAL]`

Three directions, pick by appetite:

1. **Let GitHub build the image for you.** In part 2 you built locally and deployed
   by hand. The workflows in this repo move the **build** half to CI — GitHub flow:
   merge to `main` → an image is built and pushed, tag → that image is promoted.
   The deploy half stays manual, exactly like you did it. Needs your fork
   with Actions enabled, and `gh` pointed at your fork:
   `gh repo set-default <you>/cicd-lab-05-ignition-image-based-deploy` — you
   already ran this in the assignment setup; it's stored per clone, same as
   Labs 03/04 (also a great take-home):
   1. Open a PR with a small project change — `ci.yml` validates it (including a
      no-push image build). Merge to `main` → `deploy.yml` builds on a free
      GitHub-hosted runner and pushes to **your** GHCR namespace. Wait for that
      run to go green before the next step — there is no image to pull until
      `deploy.yml` has finished.
   2. Open the run's summary page. It prints the image name it just built. Pull it
      and point test at it — the same two commands you used all through part 2, only
      the image name is longer:
      ```bash
      docker pull ghcr.io/<your-user>/cicd-lab-05-ignition:sha-<short>
      IGNITION_TEST_IMAGE=ghcr.io/<your-user>/cicd-lab-05-ignition:sha-<short> \
        docker compose up -d ignition-test
      ```
   3. `git tag v0.1.0 && git push origin v0.1.0` → `release.yml` re-tags `:test` to
      `:v0.1.0` + `:production` — **no rebuild**. Deploy it to production (:8090) the same way,
      with `IGNITION_PRODUCTION_IMAGE`.
   4. The payoff — prove test and production run the **same image bytes**
      (`{{.Image}}` is the sha256 of the image a container runs):
      ```bash
      docker inspect -f '{{.Image}}' lab05-ignition-test
      docker inspect -f '{{.Image}}' lab05-ignition-production
      # identical sha256 → production runs the bytes the test gateway tested
      ```
   5. **Observe what's still manual:** you typed the image name twice. That last
      mile — a machine that owns the gateway, picking up the tag on its own — is
      what Lab 06 and Lab 07 automate.

2. **Go deeper on the image:** shrink the build context with
   `--progress=plain`, do layer forensics with `docker history --no-trunc`, or
   (if you have a fork with Actions) add a no-push `docker build` smoke-test
   job to `ci.yml` so a broken Dockerfile fails the PR.
3. **A first taste of Lab 06** — bake more kinds of cargo, the way the
   production image from the teaching does:
   - **A third-party module:** enable an unused `.modl` from
     `third-party-modules/` in `services/modules.json`, rebuild, deploy to test,
     find it under Config → Modules.
   - **A migrations folder:** create
     `db-migrations/0001_create_downtime_log.up.sql` with a simple
     `CREATE TABLE`, add a `COPY db-migrations/ /db-migrations/` layer, rebuild,
     and read the file back out of the image with `--entrypoint cat`. Nothing
     runs it yet — Lab 06 wires that up.
   - **An extra JAR:** add a `COPY` layer for a JAR the way the production
     image ships its RabbitMQ client into `lib/core/gateway/`. Where in the
     layer order does it belong, and why?

## Debrief (10 min)

- File-based vs image-based, now that you've run both: which failure modes did you meet on each side, and what would you pick for your own plant?
- The rollback took one command. What made it that cheap? (Immutable tags: the previous version already exists as an artifact.)
- Each deploy was a fresh gateway. Which state at your plant could **not** survive that, and where would you move it (volume? external DB)?
- In production the image goes through a registry. What changes in the mechanics, and what stays exactly the same?
