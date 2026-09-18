#!/usr/bin/env bash
#
# Put the phone probe on a real HTTPS origin.
#
# A PWA cannot exist without one: service workers, push and Add to Home Screen all require a secure
# origin with a real certificate (plan §2). So there is no version of this probe that runs from a
# file or a laptop's IP address, and that is the whole reason this script exists.
#
#   ./deploy-railway.sh --project <railway project id> [--service richos-phone-probe]
#
# WHAT IT WILL NOT DO. It will not create credentials, and it will not touch avelor or fitapp. It
# creates ONE new service, sets that service's own variables, and deploys this directory to it.
#
# NO PROJECT ID IS COMMITTED IN THIS FILE. This repository is published; a Railway project id is not
# a password, but it names infrastructure and there is no reason for it to be on the internet. Pass
# it in, or set RAILWAY_PROJECT_ID.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="richos-phone-probe"
PROJECT="${RAILWAY_PROJECT_ID:-}"
ENVIRONMENT="${RAILWAY_ENVIRONMENT:-production}"

while [ $# -gt 0 ]; do
	case "$1" in
		--project) PROJECT="$2"; shift 2 ;;
		--service) SERVICE="$2"; shift 2 ;;
		--environment) ENVIRONMENT="$2"; shift 2 ;;
		-h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

# ---------------------------------------------------------------------------
# Preflight: fail clearly, never deep inside an upload
# ---------------------------------------------------------------------------
#
# This mirrors the preflight in femcboost's scripts/deploy-avelor-staging.sh, and it exists for the
# reason recorded there after the 2026-07-31 incident: a dead Railway session does not present as an
# auth error. It presents as a mangled parse error thrown from inside the multipart upload, ten
# minutes into a misdiagnosis.
#
# NOTE ON HOW RAILWAY AUTH ACTUALLY WORKS HERE, because it is the opposite of what is often assumed:
# there is no token in the environment. Authentication is a machine-wide INTERACTIVE OAuth session
# in ~/.railway/config.json, shared across every checkout because it lives outside all of them. The
# incident note in that script is explicit that restoring it "requires a HUMAN to complete a fresh
# interactive railway login — no script can self-serve past a revoked OAuth session."
#
# A RAILWAY_TOKEN in the environment is also honored by the CLI and needs no browser, which is the
# better option for an unattended deploy. Either is fine; neither can be conjured by this script.

if ! command -v railway >/dev/null 2>&1; then
	echo "ERROR: the railway CLI is not installed." >&2
	exit 1
fi

if [ -z "${RAILWAY_TOKEN:-}" ] && ! railway whoami >/dev/null 2>&1; then
	cat >&2 <<'MSG'
ERROR: the railway CLI has no valid credential on this machine.

  `railway whoami` fails and no RAILWAY_TOKEN is set. Railway's API is almost certainly fine —
  the CLI simply has nothing to authenticate with. No script can get past this; it needs a person.

  Either of these fixes it, and the second needs no browser:

    1. railway login              (or `railway login --browserless` and open the printed link)
    2. create a project token in the Railway dashboard, then:  export RAILWAY_TOKEN=<token>

  Then re-run this script. Nothing else about the probe depends on Railway — the page, the push
  sender and every local test work without it. Only the public HTTPS origin needs this.
MSG
	exit 1
fi

if [ -z "$PROJECT" ]; then
	echo "ERROR: no Railway project. Pass --project <id> or set RAILWAY_PROJECT_ID." >&2
	echo "       (It is deliberately not hardcoded here — this repository is published.)" >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Secrets: generated here, set on the service, printed once, committed never
# ---------------------------------------------------------------------------

VAPID_ENV="$(node "$HERE/bin/generate-vapid-keys.js")"
# shellcheck disable=SC1090
eval "$(printf '%s' "$VAPID_ENV" | grep '^export ')"

# An unguessable path for an origin that is on the public internet. The plan's doctrine is that an
# unpaired caller gets a flat 404 and learns nothing; without this the origin is simply open.
ACCESS_CODE="$(node -e "process.stdout.write(require('crypto').randomBytes(12).toString('base64url'))")"

# The probe reports which build answered it, so a stale deploy cannot masquerade as a fresh one.
BUILD_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "==> project     $PROJECT"
echo "==> service     $SERVICE"
echo "==> environment $ENVIRONMENT"
echo "==> build       $BUILD_SHA"

railway link --project "$PROJECT" --environment "$ENVIRONMENT" >/dev/null 2>&1 || true

# `add` is idempotent enough for this purpose: if the service already exists the link below still
# finds it, and a second service is never created silently.
railway add --service "$SERVICE" >/dev/null 2>&1 || true
railway service "$SERVICE" >/dev/null 2>&1 || railway service link "$SERVICE" >/dev/null 2>&1 || true

echo "==> setting variables on '$SERVICE' (and on no other service)"
railway variables \
	--service "$SERVICE" \
	--set "VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY" \
	--set "VAPID_PRIVATE_KEY=$VAPID_PRIVATE_KEY" \
	--set "VAPID_SUBJECT=$VAPID_SUBJECT" \
	--set "PROBE_ACCESS_CODE=$ACCESS_CODE" \
	--set "PROBE_BUILD_SHA=$BUILD_SHA" \
	>/dev/null

echo "==> deploying $HERE"
railway up "$HERE" --path-as-root --service "$SERVICE" --environment "$ENVIRONMENT" --detach

DOMAIN="$(railway domain --service "$SERVICE" 2>/dev/null | grep -Eo '[a-z0-9.-]+\.up\.railway\.app' | head -1 || true)"

echo
echo "==================================================================="
if [ -n "$DOMAIN" ]; then
	echo "  Send him THIS link, and nothing else:"
	echo
	echo "    https://$DOMAIN/?k=$ACCESS_CODE"
	echo
	echo "  Open it in Safari on the iPhone, Share -> Add to Home Screen, then run the"
	echo "  five steps from the icon. The code is inside the manifest's start_url, so the"
	echo "  installed app keeps it."
else
	echo "  Deployed, but no public domain is attached yet. Run:"
	echo "    railway domain --service $SERVICE"
	echo "  then the link is https://<domain>/?k=$ACCESS_CODE"
fi
echo
echo "  Access code: $ACCESS_CODE"
echo "  The VAPID private key was set on the service and printed nowhere. It is not in"
echo "  this repository and must not be put in one."
echo "==================================================================="
