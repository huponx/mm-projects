# t-projects

Workspace with the repositories of the platform. The root is not a git repository; each folder below is its own repository.

| Folder | What it is |
| --- | --- |
| `identity` | OAuth/OIDC server, users, roles, permissions, token exchange (gRPC admin API + HTTP sign in) |
| `gatekeeper` | HTTP gateway (BFF): JSON to gRPC with an exchanged token per upstream, `routes.yaml` |
| `dictionary` | gRPC dictionary service: word lookup, saved words, Anki export |
| `courier` | gRPC notification gateway and its worker (mail, Telegram) |
| `bvchain`, `bvreport` | Jobs that use courier |
| `web` | Web apps (`dict`, `bill`, `admin`, `auth`) and the shared UI kit |
| `gocommon` | Shared Go libraries |
| `protos`, `protogen` | Protobuf contracts and the generated stubs |
| `db-migration` | Flyway migrations, local Postgres and Redis (docker) |
| `actions` | Reusable GitHub workflows |
| `charts`, `mm-deploy`, `mm-ansible` | Helm charts, ArgoCD Applications, cluster provisioning |

## Local stack

`make up` starts everything (see [LOCAL.md](LOCAL.md)); `make status` shows what runs. The card images of the dictionary are stored in `.local/images` (`make reset` deletes them).

## Local ports

Every process of the local stack has its own port. They must not collide: the defaults of several services are equal
(gRPC 9090, HTTP 8080), so each service except identity gets an explicit local port, set by `scripts/local.sh` and by the
`.env.example` of the service. Inside a cluster every service has its own pod, so there the defaults (gRPC 9090, courier
worker health 8081) are fine.

| Port | Service | Protocol | Set by | Default of the service |
| --- | --- | --- | --- | --- |
| 3000 | web `dict` | HTTP (vite) | `web/apps/dict/vite.config.ts` | |
| 3001 | web `bill` | HTTP (vite) | `web/apps/bill/vite.config.ts` | |
| 3002 | web `admin` | HTTP (vite) | `web/apps/admin/vite.config.ts` | |
| 3003 | web `auth` (only `pnpm dev:auth`; `make up` serves its build from identity) | HTTP (vite) | `web/apps/auth/vite.config.ts` | |
| 5432 | Postgres | TCP (docker) | `db-migration/docker-compose.yml` | |
| 6379 | Redis | TCP (docker) | `db-migration/docker-compose.yml` | |
| 8080 | identity | HTTP (OAuth/OIDC, sign in) | `HTTP_PORT` | 8080 |
| 8081 | gatekeeper | HTTP | `PORT` | 8080 |
| 8082 | courier worker | HTTP (health) | `HEALTH_ADDR` | `:8081` |
| 9090 | identity | gRPC | `PORT` | 9090 |
| 9091 | courier | gRPC | `PORT` | 9090 |
| 9092 | dictionary | gRPC | `PORT` | 9090 |

Rules when adding a service: take the next free number of its range (web 30xx, HTTP 80xx, gRPC 90xx), put it in
`scripts/local.sh`, in the `.env.example` of the service and in this table.

`bvchain` and `bvreport` are jobs: they listen on nothing.
