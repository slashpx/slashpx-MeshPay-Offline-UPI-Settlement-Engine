# Deploying MeshPay to Render

This project is a Spring Boot 3.3.5 / Java 17 app (`upi-offline-mesh`) that serves a
Thymeleaf dashboard at `/` and a REST API under `/api`. It uses an **in-memory H2
database**, so it needs no managed database — but it also keeps no data across restarts.

Render has no native Java runtime, so we deploy as a **Docker web service**. Everything
needed is already committed:

| File | Purpose |
| --- | --- |
| `Dockerfile` | Two-stage build: Maven 3.9.9 + JDK 17 builds the fat jar, a Temurin 17 JRE Alpine image runs it as a non-root user. |
| `.dockerignore` | Keeps `target/`, `.git/` and IDE files out of the build context. |
| `render.yaml` | Blueprint describing the web service, region, health check and env vars. |
| `application-prod.properties` | Production profile: H2 console off, no stack traces in responses, proxy headers honoured, graceful shutdown. |

Two changes were made to `application.properties` so the app works on Render:

- `server.port=${PORT:8080}` — Render assigns a port via `$PORT`. A service that ignores
  it never passes the health check and the deploy is rolled back. Local runs still use 8080.
- `spring.h2.console.enabled=${H2_CONSOLE_ENABLED:true}` — the console stays available
  locally, but it is a live SQL shell, so it is switched off in production.

---

## Pre-flight checks (do these locally first)

```bash
# 1. Clean build, same command the Docker stage runs
./mvnw -B -DskipTests package

# 2. Run the way Render will run it: injected port + prod profile
PORT=9099 SPRING_PROFILES_ACTIVE=prod java -jar target/upi-offline-mesh-0.0.1-SNAPSHOT.jar
```

Then confirm, in another terminal:

```bash
curl -i http://localhost:9099/api/server-key   # expect 200 — this is the health check path
curl -i http://localhost:9099/                 # expect 200 — the dashboard
curl -i http://localhost:9099/h2-console       # expect 404 — console must be off in prod
```

All three of these were verified on this machine before the guide was written.

If Docker Desktop is running, also build the image locally — this catches Dockerfile
problems in ~2 minutes instead of ~8 minutes of Render build log:

```bash
docker build -t meshpay:local .
docker run --rm -e PORT=9099 -e SPRING_PROFILES_ACTIVE=prod -p 9099:9099 meshpay:local
```

> Docker CLI is installed here but the daemon was not running, so the image build is the
> one step not yet verified end to end. Render will build it either way; running it
> locally first is just faster feedback.

---

## Deployment workflow

### Step 1 — Push the deploy artifacts

```bash
git add Dockerfile .dockerignore render.yaml DEPLOY.md \
        src/main/resources/application.properties \
        src/main/resources/application-prod.properties
git commit -m "Add Render Docker deployment config"
git push origin main
```

Render reads the repo from GitHub, so nothing deploys until this is pushed.

### Step 2 — Create the service from the blueprint

1. Sign in at [dashboard.render.com](https://dashboard.render.com) and connect the GitHub
   account that owns `slashpx/slashpx-MeshPay-Offline-UPI-Settlement-Engine`.
2. **New → Blueprint**, pick the repo, branch `main`.
3. Render reads `render.yaml` and proposes one web service, `meshpay-upi-settlement`.
   Confirm and **Apply**.

Prefer clicking through instead? **New → Web Service** → connect the repo → set
*Language* to **Docker**, *Branch* `main`, *Health Check Path* `/api/server-key`, and add
the env vars `SPRING_PROFILES_ACTIVE=prod` and `H2_CONSOLE_ENABLED=false`. That produces
the same service; the blueprint just keeps the config in version control.

### Step 3 — Watch the first build

The first build takes roughly 5–10 minutes: Render pulls the Maven image, downloads the
dependency tree, packages a ~50 MB fat jar, then starts the JRE stage. The deploy is live
once the log shows Tomcat started and the health check at `/api/server-key` returns 200.

Your URL will be `https://meshpay-upi-settlement.onrender.com` (Render appends a suffix if
the name is taken). Open `/` for the dashboard.

### Step 4 — Verify in production

```bash
BASE=https://meshpay-upi-settlement.onrender.com
curl -s $BASE/api/server-key | head -c 120   # RSA public key
curl -s $BASE/api/mesh/state                 # mesh + device state
curl -s -o /dev/null -w '%{http_code}\n' $BASE/h2-console   # must be 404
```

Then drive the demo through the dashboard: send a payment, gossip, flush the bridge, and
check `/api/transactions` reflects the settlement.

### Step 5 — Ongoing deploys

`autoDeploy: true` is set, so every push to `main` triggers a rebuild. To change that,
use Render's *Settings → Auto-Deploy*, or **Manual Deploy → Deploy latest commit** for
one-off deploys. Rollback is **Deploys → previous deploy → Rollback**.

---

## Things to know about running this on Render

**The free plan sleeps.** After 15 minutes with no traffic the instance spins down, and
the next request takes 30–60 seconds to wake it. Because the keypair and the H2 database
are both created at startup, waking up means a **fresh RSA keypair and an empty ledger** —
any client that cached the old public key from `/api/server-key` must re-fetch it. For a
demo you'll show live, either upgrade to the Starter plan ($7/mo, no sleeping) or hit the
URL a minute before presenting.

**Data is ephemeral by design.** `spring.jpa.hibernate.ddl-auto=create-drop` on an
in-memory H2 DB means every restart — including every redeploy — resets accounts and
transactions to the seeded demo state. That is correct for a demo and wrong for anything
else. To persist, add a Render PostgreSQL instance, swap the H2 dependency for
`org.postgresql:postgresql`, point `spring.datasource.url` at Render's
`fromDatabase` connection string, and move `ddl-auto` to `validate` with a real migration
tool (Flyway or Liquibase).

**The RSA keypair is regenerated on every boot.** `ServerKeyHolder` says so in its own
comments. Fine for a demo; a real deployment reads the private key from a KMS or an
injected secret so restarts don't invalidate outstanding encrypted packets.

**Memory headroom is tight.** The free instance gets 512 MB. `-XX:MaxRAMPercentage=75` in
the `ENTRYPOINT` keeps the JVM heap inside that budget so the container isn't OOM-killed.
If you see exit code 137 in the logs, that's the container being killed for memory —
lower the percentage or move to a paid instance.

**`/api/mesh/reset` and `/api/mesh/flush` are unauthenticated POSTs.** On a public URL,
anyone who finds the service can wipe the demo state mid-presentation. Before sharing the
link widely, consider adding Spring Security with a single basic-auth user over the
mutating `/api/**` routes, or keep the URL private.

---

## Troubleshooting

| Symptom in the Render log | Cause and fix |
| --- | --- |
| "Port scan timeout reached, no open ports detected" | The app isn't reading `$PORT`. Confirm `server.port=${PORT:8080}` is in the committed `application.properties`. |
| Health check fails, service marked unhealthy | `healthCheckPath` must be a path that returns 2xx without auth — `/api/server-key`. Check the app didn't crash on startup first. |
| Exit code 137 | Container OOM-killed. Lower `MaxRAMPercentage` or upgrade the instance. |
| `COPY --from=build /build/target/*.jar` matched no files | The Maven stage failed. Scroll up in the build log for the real compilation error. |
| Build times out or is very slow | The `dependency:go-offline` layer is cached only while `pom.xml` is unchanged; any POM edit re-downloads the tree. Expected. |
| First request after idle hangs ~50s | Free-plan cold start. Not a bug. |
