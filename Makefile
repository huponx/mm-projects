# Local development stack from the workspace root (details and manual steps: LOCAL.md).
# Processes run in the background; logs and pid files are in .local/run.
.PHONY: help up backend web down down-backend down-web down-all status logs setup db reset test

help:
	@printf '%s\n' \
		'make up        Postgres/Redis + schema, identity-setup, identity, gatekeeper, web apps (everything)' \
		'make backend   the same without the web apps' \
		'make web       only the web apps (dict :3000, bill :3001, admin :3002)' \
		'make down      stop identity, gatekeeper, courier and the web apps (containers keep running)' \
		'make down-backend  stop only identity, gatekeeper and courier' \
		'make down-web      stop only the web apps' \
		'make down-all  stop them and the Postgres/Redis containers' \
		'make status    what runs, with the URLs' \
		'make logs      follow all logs (make logs N=identity for one)' \
		'make setup     re-run identity-setup (first admin, gateway client; safe to repeat)' \
		'make db        only Postgres, Redis and the schema' \
		'make reset     wipe the database volumes and local keys (asks first)' \
		'make test      go tests of identity, gatekeeper, courier and the web checks' \
		'' \
		'WITH_COURIER=1 make up   also start courier and its worker' \
		'SETUP_ADMIN_PASSWORD=... make up   admin password (default in scripts/local.sh)'

up:
	@scripts/local.sh up

backend:
	@scripts/local.sh up backend

web:
	@scripts/local.sh up web

down:
	@scripts/local.sh down

down-backend:
	@scripts/local.sh down backend

down-web:
	@scripts/local.sh down web

down-all:
	@scripts/local.sh down all

status:
	@scripts/local.sh status

logs:
	@scripts/local.sh logs $(N)

setup:
	@scripts/local.sh setup

db:
	@scripts/local.sh db

reset:
	@scripts/local.sh reset

test:
	cd identity && go test -race ./...
	cd gatekeeper && go test -race ./...
	cd courier && go test ./...
	cd web && pnpm run ci
