#!/usr/bin/env bash
# The RichConnect review host (richos/mobile/review-mock): the hosted mock backend Apple and
# Google reviewers pair the ordinary store builds with. Node only: the conformance corpus replayed
# against it, its behavior, push through the production Connect Worker handler over its real D1
# schema, the access page, the operator CLI and the deploy template. The workerd runtime case uses
# the Wrangler on PATH when there is one and skips with the reason when there is not. No network,
# no simulator, no emulator, no device, no deploy. 160 tests in 1.2 s, measured 2026-09-24.
# run-tests: no-host-screen: Node only
# run-tests: inputs richos/app/scripts/review-mock.test.sh richos/mobile/review-mock richos/mobile/conformance/vectors richos/mobile/core/client.js richos/mobile/platform/native.js richos/web/web-app/lib richos/app/ui/qr.js richos/mobile/service/connect-worker.mjs richos/mobile/service/connect richos/mobile/test/connect-fixture.cjs
# run-tests: covers richos/mobile/review-mock/bin/review-secrets.mjs richos/mobile/review-mock/dev/local.mjs richos/mobile/review-mock/src/attachments.mjs richos/mobile/review-mock/src/codec.mjs richos/mobile/review-mock/src/config.mjs richos/mobile/review-mock/src/host.mjs richos/mobile/review-mock/src/limits.mjs richos/mobile/review-mock/src/pages.mjs richos/mobile/review-mock/src/phone.mjs richos/mobile/review-mock/src/portal.mjs richos/mobile/review-mock/src/push.mjs richos/mobile/review-mock/src/qr.mjs richos/mobile/review-mock/src/registration.mjs richos/mobile/review-mock/src/script.mjs richos/mobile/review-mock/src/session.mjs richos/mobile/review-mock/src/signing.mjs richos/mobile/review-mock/src/wav.mjs richos/mobile/review-mock/src/wire.mjs richos/mobile/review-mock/src/worker.mjs richos/mobile/review-mock/test/conformance.test.mjs richos/mobile/review-mock/test/helpers.mjs richos/mobile/review-mock/test/host.test.mjs richos/mobile/review-mock/test/portal.test.mjs richos/mobile/review-mock/test/push.test.mjs richos/mobile/review-mock/test/reference-client.test.mjs richos/mobile/review-mock/test/runtime.test.mjs richos/mobile/review-mock/test/secrets.test.mjs richos/mobile/review-mock/test/template.test.mjs richos/mobile/review-mock/wrangler.example.toml
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo '  NOT RUN  review-mock: Node is unavailable'
  exit 2
fi

cd "$ROOT/richos/mobile/review-mock"
node --test test/*.test.mjs
echo '  PASS  review-mock: corpus conformance, review host behavior, push through the Connect handler, access page, CLI and template'
