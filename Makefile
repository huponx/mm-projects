# Local development stack from the workspace root (details and manual steps: LOCAL.md).
# Processes run in the background; logs and pid files are in .local/run.
.PHONY: help up backend web dict-seed dict-unseed dict-testdata-status down down-backend down-web down-all status logs setup db reset test upgrade zip unzip replace checkout main git-reset

# The Go modules that have their own `make upgrade` (gocommon first: the others depend on it).
GO_MODULES := gocommon identity gatekeeper dictionary courier bvchain

help:
	@printf '%s\n' \
		'make up        Postgres/Redis + schema, identity-setup, identity, gatekeeper, dictionary and dictionary-worker, web apps (everything; card images and audio are stored in .local/files)' \
		'make backend   the same without the web apps (card files in .local/files)' \
		'make web       only the web apps (dict :3000, bill :3001, admin :3002)' \
		'make down      stop identity, gatekeeper, dictionary, dictionary-worker, courier and the web apps (containers keep running)' \
		'make down-backend  stop only identity, gatekeeper, dictionary, dictionary-worker and courier' \
		'make down-web      stop only the web apps' \
		'make down-all  stop them and the Postgres/Redis containers' \
		'make status    what runs, with the URLs' \
		'make logs      follow all logs (make logs N=identity for one)' \
		'make setup     re-run identity-setup (first admin, gateway client; safe to repeat)' \
		'make db        only Postgres, Redis and the schema' \
		'make reset     wipe the database volumes, local keys and card images (asks first)' \
		'make upgrade   make upgrade in every Go module (PATCH=1 make upgrade: patch versions only)' \
		'make checkout main   every sub-folder that is a git repository goes to main (stops when one has uncommitted changes)' \
		'make git-reset   asks first, then drops every uncommitted change and deletes new uncommitted files in the sub-folders that are git repositories' \
		'make zip       pack this folder into t-projects.ipx (NAME=name for another name; a zip; without the ignored folders, see IGNORE)' \
		'make unzip     unpack an archive: make unzip FROM=/path/file.ipx TO=/target (default: t-projects.ipx into this folder; .git folders are never overwritten; a repository in TO goes to main and pulls origin main first)' \
		'make replace TO=/path   copy the sources over the folder /path (never touches its .git)' \
		'make dict-seed   add saved words for a user to try the export in parts (N=60 words, KB=20 per word, EMAIL=admin@example.com)' \
		'make dict-unseed   remove those words, the export jobs of the user and their part files' \
		'make dict-testdata-status   how many seeded words and which export jobs the user has' \
		'make test      go tests of identity, gatekeeper, dictionary, courier and the web checks' \
		'' \
		'WITH_COURIER=1 make up   also start courier and its worker' \
		'WITH_DICTIONARY=0 make up   do not start the dictionary service (and no .local/files)' \
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

# test data of the dictionary service (scripts/dict-testdata.sh): N words of KB kilobytes for the user EMAIL
dict-seed:
	@scripts/dict-testdata.sh seed

dict-unseed:
	@scripts/dict-testdata.sh remove

dict-testdata-status:
	@scripts/dict-testdata.sh status

setup:
	@scripts/local.sh setup

db:
	@scripts/local.sh db

reset:
	@scripts/local.sh reset

test:
	cd identity && go test -race ./...
	cd gatekeeper && go test -race ./...
	cd dictionary && go test -race ./...
	cd courier && go test ./...
	cd web && pnpm run ci
	@if command -v helm >/dev/null; then \
		(cd dictionary/charts/dictionary && helm lint . -f ci/full-values.yaml) && \
		(cd dictionary/charts/dictionary-worker && helm lint . -f ci/full-values.yaml); \
	else echo 'helm not found: skipping the dictionary chart lint'; fi

upgrade:
	@for m in $(GO_MODULES); do \
		echo "==> $$m"; \
		$(MAKE) --no-print-directory -C $$m upgrade || exit 1; \
	done

# What zip and replace leave out: local state, caches output.
IGNORE := .local .memsearch .pnpm-store node_modules dist coverage .turbo .DS_Store .venv mm-deploy-diffs go-anki-deck
# NAME is the name of the archive without the extension (make zip NAME=backup -> backup.ipx).
NAME ?= t-projects
IPX ?= $(NAME).ipx

# A zip with the extension .ipx. The archive itself is not packed again.
zip:
	@rm -f $(IPX) $(IPX).zip
	@zip -qry $(IPX).zip . -x '*.ipx' '*.ipx.zip' $(foreach i,$(IGNORE),'$(i)/*' '*/$(i)/*' '*/$(i)' '$(i)')
	@mv $(IPX).zip $(IPX)
	@echo "$(IPX) ($$(du -h $(IPX) | cut -f1))"

# The reverse of zip: unpacks the archive FROM (default t-projects.ipx) into the folder TO (default: here); files that exist are overwritten, except what is in a .git folder. A sub-folder of TO that is a git repository is put on main and pulls
# origin main first (the unzip stops when one has uncommitted changes or cannot pull); without .git it is unpacked as is.
unzip:
	@test -f "$(or $(FROM),t-projects.ipx)" || { echo "$(or $(FROM),t-projects.ipx) not found (make unzip FROM=/path/file.ipx TO=/target)" >&2; exit 1; }
	@mkdir -p "$(or $(TO),.)"
	@scripts/checkout-main.sh "$(or $(TO),.)" main pull
	@unzip -qo "$(or $(FROM),t-projects.ipx)" -d "$(or $(TO),.)" -x '.git/*' '*/.git/*'
	@echo "unpacked $(or $(FROM),t-projects.ipx) into $(or $(TO),.)"

# Copies the sources over TO (files that exist are overwritten, nothing is deleted); a .git folder is left alone.
replace:
	@test -n "$(TO)" || { echo "usage: make replace TO=/path" >&2; exit 1; }
	@test -d "$(TO)" || { echo "$(TO) is not a folder" >&2; exit 1; }
	@rsync -a --exclude='.git' --exclude='*.ipx' $(foreach i,$(IGNORE),--exclude='$(i)') ./ "$(TO)/"
	@echo "sources copied into $(TO)"

# Puts every sub-folder that is a git repository on main; stops, listing the files, when one has uncommitted changes.
# (`make checkout main`: the word main is only there to read well, the branch is main.)
checkout:
	@scripts/checkout-main.sh . main

main:
	@:

# git reset --hard and git clean -fd in every sub-folder that is a git repository; it lists what is lost and asks "yes" first.
git-reset:
	@scripts/git-reset.sh .
