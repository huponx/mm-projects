# Run everything locally

Postgres, Redis, identity, gatekeeper, courier (+ worker) and the three web apps on one machine. Every command is
run from this folder (the root of the workspace) unless it says `cd`. Use one terminal per long running process.

Needs: Docker, Go (see `go.mod` of each service), Node 20 with `corepack` (pnpm), `openssl`.

## Quick start (one command)

```sh
make up              # Postgres + Redis + schema, identity-setup, identity, gatekeeper, the three web apps
make status          # what runs and the URLs
make logs            # follow the logs (make logs N=gatekeeper for one)
make down            # stop all processes; make down-backend / make down-web stop only one side;
                     # make down-all also stops the Postgres/Redis containers
```

Then open http://localhost:3002 and sign in as `admin@example.com` with `Correct-Horse-Battery-9` (override with
`SETUP_ADMIN_PASSWORD=... make up` the first time). Other targets: `make backend` (no web apps), `make web` (only the
web apps), `make setup` (re-run `identity-setup`), `make reset` (wipe database and keys), `make test`, and
`WITH_COURIER=1 make up` to start courier and its worker as well. It is `scripts/local.sh` underneath: it builds
the Go binaries into `.local/bin`, keeps keys in `.local/`, and writes pid files and logs to `.local/run/`. The manual
steps below are what it automates.

## Ports

| What | Port | Notes |
| --- | --- | --- |
| Postgres | 5432 | db `app`, user/password `postgres` |
| Redis | 6379 | |
| identity HTTP (OAuth/OIDC, sign in pages) | 8080 | default; issuer `http://localhost:8080` |
| identity gRPC (admin API) | 9090 | default; called by the gateway |
| gatekeeper (the gateway the web apps call) | 8081 | what `apps/*/public/config.js` points at |
| dictionary gRPC (`make up` starts it; `WITH_DICTIONARY=0` skips it) | 9092 | `PORT` (`DICTIONARY_ISSUER`, `DICTIONARY_JWKS_URL`; see `dictionary/.env.example`) |
| courier gRPC (notifications, optional) | 9091 | `PORT` (default 9090, see below) |
| courier worker health (optional) | 8082 | `HEALTH_ADDR` (default `:8081`, see below) |
| web `dict` / `bill` / `admin` | 3000 / 3001 / 3002 | Vite dev servers |

identity and gatekeeper use their defaults. The defaults of courier (gRPC 9090, worker health 8081) collide with
identity and the gateway, so `courier/.env.example` moves them to 9091 and 8082 (this guide sets them explicitly too).
The test scripts use their own ports (identity 18080/19090, gatekeeper 18081, web e2e 18180/19190/18082/13002,
UI 13000) and never touch the ones above, so a tests run and this stack can be up together.

## 1. Postgres, Redis and the schema

```sh
(cd db-migration && docker compose up --build -d)   # Postgres, Redis, then Flyway migrate (V1..V11)
```

`docker compose down -v` in `db-migration` resets everything. All services below read the database with these
variables, export them in every terminal that starts a Go service:

```sh
export ENV=local POSTGRES_HOST=localhost POSTGRES_DB=app POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres \
       POSTGRES_SSLMODE=disable REDIS_HOST=localhost
```

## 2. Keys, one time

Kept in `.local/` (do not commit it):

```sh
mkdir -p .local
openssl ecparam -name prime256v1 -genkey -noout -out .local/k1.pem
echo "k1:$(openssl rand -base64 32)" > .local/mfa.key
echo "k1:$(openssl rand -base64 32)" > .local/session.key
```

## 3. identity

Environment shared by the server and `identity-setup` (put it in a file and `source` it if you prefer):

```sh
export IDENTITY_ISSUER=http://localhost:8080
export IDENTITY_SIGNING_KEY_FILE=$PWD/.local/k1.pem IDENTITY_SIGNING_KEY_ID=k1
export IDENTITY_MFA_KEY=$(cat .local/mfa.key)
export SETUP_ADMIN_PASSWORD='Correct-Horse-Battery-9'
# optional, to really send reset / MFA mails through courier (step 6); empty: the links are logged
# export COURIER_TARGET=localhost:9091
```

First admin and the client of the gateway (once; `identity-setup` talks straight to Postgres, it is the same program the Job runs in the cluster):

```sh
cd identity
echo "$(openssl rand -hex 16)" > ../.local/gatekeeper.secret      # the client secret is chosen here, not printed
export GATEKEEPER_CLIENT_SECRET=$(cat ../.local/gatekeeper.secret)
# keep_password: sign in with SETUP_ADMIN_PASSWORD as it is (a real setup forces a change at the first sign in)
SETUP_CONFIG='{"admin":{"email":"admin@example.com","keep_password":true},
  "clients":[{"id":"gatekeeper-dev","type":"confidential","resource":"gatekeeper","secret_env":"GATEKEEPER_CLIENT_SECRET",
    "redirect_uris":["http://localhost:8081/auth/callback"],
    "post_logout_uris":["http://localhost:3000/","http://localhost:3001/","http://localhost:3002/"],
    "grants":["authorization_code","refresh_token","client_credentials","urn:ietf:params:oauth:grant-type:token-exchange"]}],
  "exchange_policies":[{"client":"gatekeeper-dev","audience":"identity","max_depth":1}]}' \
  go run ./cmd/identity-setup
```

Add an app origin later by running it again with the extra URI in `post_logout_uris` (existing URIs are kept; the admin is skipped because one exists).

Defaults need no `HTTP_PORT`/`PORT` exports; identity listens on 8080 (HTTP) and 9090 (gRPC).

Start the server (keep it running):

```sh
# the sign in pages are the React app web/apps/auth: build it once, identity serves the build
(cd web && corepack enable && pnpm install && pnpm --filter @huponx/auth build)
cd identity && IDENTITY_UI_DIR=$PWD/../web/apps/auth/dist go run ./cmd/identity   # http://localhost:8080/healthz
```

## 4. gatekeeper (the gateway)

The routes are those of the chart (`gatekeeper/routes.yaml`: identity admin API, used by the
`admin` app). `make routes` writes `routes.local.yaml` from it with the upstream `localhost:9090`, identity's gRPC port:

```sh
cd gatekeeper
make routes
ENV=local PORT=8081 \
GATEKEEPER_PUBLIC_URL=http://localhost:8081 \
GATEKEEPER_UI_ORIGINS=http://localhost:3000,http://localhost:3001,http://localhost:3002 \
GATEKEEPER_ROUTES_FILE=$PWD/routes.local.yaml \
GATEKEEPER_IDENTITY_ISSUER=http://localhost:8080 \
GATEKEEPER_CLIENT_ID=gatekeeper-dev GATEKEEPER_CLIENT_SECRET=$(cat ../.local/gatekeeper.secret) \
GATEKEEPER_AUDIENCE=gatekeeper \
GATEKEEPER_SESSION_KEY=$(cat ../.local/session.key) \
  go run ./cmd/gatekeeper                  # http://localhost:8081/healthz
```

`ENV=local` is required here: without it gatekeeper refuses to start (`GATEKEEPER_PUBLIC_URL must be https outside
ENV=local`, because outside local the session cookie is `Secure`). It is already exported if you ran the `export` block
of step 1 in this terminal; the explicit `ENV=local` above makes the command work in a fresh one.

`GATEKEEPER_UI_ORIGINS` must list every web app origin (CORS with cookies), and each one must be a post logout URI
of the client (step 3). The browser, the apps and the gateway are all on `localhost`, so the session cookie works
over plain http (`ENV=local`).

## 5. Web apps

Install once:

```sh
cd web
corepack enable          # gives you the pnpm pinned by packageManager
pnpm install
```

Each app is its own Vite dev server on its own port. Start the ones you need, **one terminal per app**, from `web`:

| App | Command | URL | What it is |
| --- | --- | --- | --- |
| `admin` | `pnpm dev:admin` | http://localhost:3002 | identity administration: users, roles, clients, exchange policies, MFA |
| `dict` | `pnpm dev:dict` | http://localhost:3000 | dictionary: look words up (English or English-Vietnamese), save words, export an Anki deck (needs `dictionary:word:read` / `dictionary:word:write` and the dictionary service) |
| `bill` | `pnpm dev:bill` | http://localhost:3001 | same frame for the bill service, sample page `Invoices` |

`make dev-admin`, `make dev-dict` and `make dev-bill` do the same.

The sign in pages (`web/apps/auth`) are not one of these: identity serves their build (step 3). To change them with hot
reload run `pnpm dev:auth` (http://localhost:3003, it proxies `/auth-api` to identity on 8080) and open the page there.

Or all three at once in a single terminal (output is interleaved):

```sh
pnpm dev:dict & pnpm dev:bill & pnpm dev:admin
```

Stop them with Ctrl+C (and `kill %1 %2` for the background ones).

Open an app: you are sent to the identity login page (`admin@example.com` / the bootstrap password), then back to
the app. The cookie session belongs to the gateway, so signing in on one app signs you in on the others too
(same `localhost`).

- **Ports are fixed** (`strictPort`): 3000, 3001 and 3002 are the origins registered in step 3 (post logout URIs)
  and in `GATEKEEPER_UI_ORIGINS` (step 4). If a port is taken Vite stops instead of choosing another one, because
  another port would be an unknown origin (CORS and logout would fail).
- **`dict` talks to the dictionary service** (`/api/dictionary/...`, `make up` starts it; restart gatekeeper after
  adding the service so it loads the routes). The menu and the buttons need `dictionary:word:read` (look up, list)
  and `dictionary:word:write` (save, delete, export): the admin has `*`; for another user create a role with
  `dictionary:word:*` in the admin app. Audio plays straight from the dictionary sources (CSP `media-src`).
- **`bill` is a frame.** Its menu entry (`Invoices` needs `bill:invoice:read`) only appears for a user with that
  permission, and its page calls `/api/bill/invoices`, which no service backs yet, so the gateway answers 404 and
  the page shows it.
- **`API_BASE`** of each app is in `apps/<app>/public/config.js` (`http://localhost:8081`, the gateway of step 4).

## 6. courier (optional)

Only needed to deliver mails and Telegram messages (password reset, MFA notices). Without it identity logs the
links when `ENV=local` and `COURIER_TARGET` is empty.

```sh
# Redis is already running (step 1)
cd courier
PORT=9091 go run ./cmd/courier             # gRPC, open without auth because ENV=local
HEALTH_ADDR=:8082 SMTP_HOST=localhost SMTP_PORT=1025 SMTP_FROM=noreply@example.com go run ./cmd/worker
```

Set `COURIER_TARGET=localhost:9091` in identity (step 3) and restart it. Sending needs `TELEGRAM_BOT_TOKEN` or
SMTP (a local catcher such as MailHog on 1025 works); see `courier/README.md` for all variables and
`courierctl` to send a test message.

## 7. Check it works

```sh
curl -s localhost:8080/healthz; curl -s localhost:8081/healthz        # both answer ok
curl -si -H 'Origin: http://localhost:3002' localhost:8081/auth/me | head -5   # 401 + CORS headers: not signed in
```

In the browser, sign in at http://localhost:3002, create a role, then create a user without roles, sign out and in
as that user: no menu entries and `GET /api/roles` answers 403.

## Tests

| Where | Command |
| --- | --- |
| identity | `cd identity && make test` and `POSTGRES_PASSWORD=postgres make e2e` |
| gatekeeper | `cd gatekeeper && go test ./...` and `scripts/e2e.sh` (needs the Postgres variables of step 1) |
| courier | `cd courier && go test ./...` |
| web | `cd web && make ci` (lint, typecheck, test, build) |
| admin UI against the real backend | `cd web && make e2e` (starts its own identity, gatekeeper and built admin app on separate ports; needs `pnpm exec playwright install chromium` once) |

The e2e scripts use their own ports (see the table above), so they can run while this stack is up.

## Troubleshooting

- **`GATEKEEPER_PUBLIC_URL must be https outside ENV=local`**: `ENV=local` is not set in that terminal (identity, courier and gatekeeper all need it for plain http).
- **`address already in use`**: another process holds the port (see the table). Check with `lsof -i :<port>`; courier needs the 9091/8082 of step 6, not its defaults.
- **Login loops or `bad_state`**: open the apps on `localhost`, not `127.0.0.1`, and clear the cookies of `localhost`.
- **CORS error in the console**: the origin of the app is not in `GATEKEEPER_UI_ORIGINS` (restart the gateway after changing it).
- **403 on every admin call**: the user has no role with the `identity:*` permissions; the bootstrap admin has them.
- **`exchange` / `access_denied` in the gateway log**: run the `exchange set --audience identity` of step 3 for the client the gateway uses.
- **Logout fails**: the app origin must be a post logout URI of the client (`client add-uri`).
- **Go build cannot find `gocommon` / `protogen`**: the services expect sibling checkouts through `go.work` or `replace`; see the README of the service.
