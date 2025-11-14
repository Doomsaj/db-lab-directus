#!/bin/sh
set -eu

DIRECTUS_URL="${DIRECTUS_URL:-http://localhost:8055}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-sajjadxw1z}"
RETRIES=${RETRIES:-60}
SLEEP=${SLEEP:-2}

echo "Directus register script starting. DIRECTUS_URL=$DIRECTUS_URL"

wait_for_directus() {
  echo "Waiting for Directus health..."
  i=0
  while [ $i -lt "$RETRIES" ]; do
    i=$((i+1))
    if curl -fsS "$DIRECTUS_URL/_/health" >/dev/null 2>&1; then
      echo "Directus healthy via /_/health"
      return 0
    fi
    if curl -fsS "$DIRECTUS_URL/server/health" >/dev/null 2>&1; then
      echo "Directus healthy via /server/health"
      return 0
    fi
    if curl -fsS "$DIRECTUS_URL/health" >/dev/null 2>&1; then
      echo "Directus healthy via /health"
      return 0
    fi
    printf "waiting for directus (%s/%s)...\n" "$i" "$RETRIES"
    sleep "$SLEEP"
  done
  echo "ERROR: Directus did not become healthy after $RETRIES tries." >&2
  return 1
}

get_access_token() {
  echo "Attempting to login as $ADMIN_EMAIL..."
  LOGIN_PAYLOAD=$(printf '{"email":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
  for ep in "$DIRECTUS_URL/auth/login" "$DIRECTUS_URL/_/auth/login" "$DIRECTUS_URL/api/auth/login"; do
    echo "Trying login endpoint: $ep"
    TOKEN_JSON="$(curl -sS -X POST "$ep" -H 'Content-Type: application/json' -d "$LOGIN_PAYLOAD" || true)"
    if [ -z "$TOKEN_JSON" ]; then
      echo "No response from $ep"
      continue
    fi
    case "$TOKEN_JSON" in
      *"access_token"*)
        ;;
      *"data"*) 
        ;;
      *)
        echo "Login response (no token): $TOKEN_JSON"
        ;;
    esac

    ACCESS_TOKEN="$(printf '%s' "$TOKEN_JSON" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    if [ -z "$ACCESS_TOKEN" ]; then
      ACCESS_TOKEN="$(printf '%s' "$TOKEN_JSON" | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*{[^}]*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    fi

    if [ -n "$ACCESS_TOKEN" ]; then
      echo "Login successful, token obtained."
      printf '%s' "$ACCESS_TOKEN"
      return 0
    fi
  done

  return 1
}

create_collection_if_missing() {
  collection="$1"
  echo "Ensuring collection metadata exists for: $collection"

  resp="$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" "$DIRECTUS_URL/collections/$collection" || true)"

  if printf '%s' "$resp" | grep -q '"data"'; then
    echo "✔ collection metadata '$collection' already exists."
    return 0
  fi

  create_payload=$(cat <<JSON
{
  "collection": "$collection",
  "hidden": false,
  "icon": "table"
}
JSON
)
  echo "Creating collection metadata for $collection ..."
  create_resp="$(curl -sS -X POST "$DIRECTUS_URL/collections" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$create_payload" || true)"

  echo "Create response: $create_resp"

  check="$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" "$DIRECTUS_URL/collections/$collection" || true)"
  if printf '%s' "$check" | grep -q '"data"'; then
    echo "✔ collection metadata '$collection' created."
    return 0
  fi

  echo "ERROR: failed to create collection metadata for $collection. Response: $create_resp" >&2
  return 1
}

if ! wait_for_directus; then
  echo "Directus not healthy. Exiting." >&2
  exit 1
fi

ACCESS_TOKEN=""
if ! ACCESS_TOKEN="$(get_access_token)"; then
  echo "ERROR: could not obtain access token. Possible reasons:" >&2
  echo "  - admin user does not exist (Directus creates it only on first DB init when ADMIN_EMAIL/PASSWORD env are set)" >&2
  echo "  - wrong ADMIN_EMAIL/ADMIN_PASSWORD" >&2
  echo "  - Directus version uses a different auth path" >&2
  echo "Login response below for debugging:"
  curl -sSf "$DIRECTUS_URL/_/users" || true
  exit 1
fi

collections="products customers orders order_items invoices invoice_items employees employee_time_logs crm_companies crm_contacts crm_leads crm_activities"

for c in $collections; do
  if ! create_collection_if_missing "$c"; then
    echo "Warning: collection $c may not be created properly. Continue..." >&2
  fi
done

echo "Done. If physical DB tables exist and have primary keys, open Directus Admin and 'Refresh' the collection to import fields."