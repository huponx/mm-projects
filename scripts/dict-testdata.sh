#!/usr/bin/env bash
# Test data of the dictionary service for the local stack (see LOCAL.md): saved words for a user, to try the export
# in parts (an export job) without typing hundreds of words.
#
#   scripts/dict-testdata.sh seed     add N saved words to the user (default 60); safe to run again
#   scripts/dict-testdata.sh remove   delete the seeded words, the export jobs of the user and their files
#   scripts/dict-testdata.sh status   how many seeded words and which export jobs the user has
#
# Variables: EMAIL (default admin@example.com), N (words, default 60), KB (size of the content of a word in KB,
# default 20, at most 60: a bigger card makes a deck with fewer words per part), PSQL (the psql command, default the
# container of `make up`). The words are named seedword1, seedword2, ... and go straight into the database, so the
# limit of saved words does not apply. A word that is exported and removed by a job is not seeded again as the same
# number unless you run `remove` first (seed adds the missing numbers only).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMAIL=${EMAIL:-admin@example.com}
N=${N:-60}
KB=${KB:-20}
PSQL=${PSQL:-docker exec -i db-migration-postgres-1 psql -U postgres -d app}
PREFIX=seedword

case "$N" in '' | *[!0-9]*) echo "N must be a number" >&2; exit 2 ;; esac
case "$KB" in '' | *[!0-9]*) echo "KB must be a number" >&2; exit 2 ;; esac
[ "$KB" -ge 1 ] && [ "$KB" -le 60 ] || { echo "KB must be between 1 and 60" >&2; exit 2; }

q() { $PSQL -q -v ON_ERROR_STOP=1 -v "email=$EMAIL" -v "n=$N" -v "chunks=$((KB * 1000 / 32))" -v "prefix=$PREFIX" "$@"; }

user_id() {
  local id
  # psql does not replace :variables in a -c string, only in what it reads from the input
  id=$(echo "SELECT id FROM identity_users WHERE email = :'email';" | q -At)
  [ -n "$id" ] || { echo "no user with the email $EMAIL (EMAIL=... to choose another)" >&2; exit 1; }
  echo "$id"
}

recount() { # the counter of the words in the list follows the rows
  q <<'SQL'
INSERT INTO dictionary_user_stats (user_id, listed)
SELECT u.id, (SELECT count(*) FROM dictionary_saved_words w WHERE w.user_id = u.id AND w.removed_at IS NULL)
FROM identity_users u WHERE u.email = :'email'
ON CONFLICT (user_id) DO UPDATE SET listed = EXCLUDED.listed;
SQL
}

case "${1:-}" in
  seed)
    user_id >/dev/null
    # random hex content: it does not compress, so KB is about the size inside the deck
    q <<'SQL'
INSERT INTO dictionary_saved_words (user_id, word, content, created_at)
SELECT u.id, :'prefix' || g,
       (SELECT string_agg(md5(random()::text || g || i), '') FROM generate_series(1, :chunks) i),
       now() - ((:n - g) || ' seconds')::interval
FROM identity_users u, generate_series(1, :n) g
WHERE u.email = :'email'
ON CONFLICT (user_id, word) DO NOTHING;
SQL
    recount
    echo "seeded up to $N words ($KB KB each) for $EMAIL"
    ;;
  remove)
    id=$(user_id)
    q <<'SQL'
DELETE FROM dictionary_export_jobs WHERE user_id = (SELECT id FROM identity_users WHERE email = :'email');
DELETE FROM dictionary_saved_words
WHERE user_id = (SELECT id FROM identity_users WHERE email = :'email') AND word ~ ('^' || :'prefix' || '[0-9]+$');
SQL
    recount
    rm -rf "$ROOT/.local/files/exports/$id"
    echo "removed the seeded words, the export jobs and the part files of $EMAIL"
    ;;
  status)
    id=$(user_id)
    q <<'SQL'
\pset format aligned
SELECT count(w.word) FILTER (WHERE w.removed_at IS NULL) AS seeded_in_list,
       count(w.word) FILTER (WHERE w.removed_at IS NOT NULL) AS seeded_removed,
       count(w.word) FILTER (WHERE w.removed_at IS NULL AND w.exported_at IS NOT NULL) AS seeded_exported_in_list,
       (SELECT listed FROM dictionary_user_stats WHERE user_id = u.id) AS all_words_in_list
FROM identity_users u LEFT JOIN dictionary_saved_words w ON w.user_id = u.id AND w.word ~ ('^' || :'prefix' || '[0-9]+$')
WHERE u.email = :'email' GROUP BY u.id;
SELECT j.id, j.status, j.total, j.built, j.parts, j.error, j.lease_until, j.expires_at
FROM dictionary_export_jobs j JOIN identity_users u ON u.id = j.user_id WHERE u.email = :'email' ORDER BY j.created_at DESC LIMIT 5;
SQL
    echo "part files: $(ls "$ROOT/.local/files/exports/$id" 2>/dev/null | wc -l | tr -d ' ')"
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
