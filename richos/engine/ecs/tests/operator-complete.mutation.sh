#!/usr/bin/env bash
#
# operator-complete.mutation.sh: PROVES operator-complete.test.sh WOULD CATCH THE
# `operator-complete` VERB GOING WRONG (richos-hq operator back-end spec r1 (c),
# r3 (c)). Each mutant removes ONE property from a throwaway copy of the engine
# and demands that the NAMED case go red. The loop is scripts/lib/mutation-harness.sh.
#
# Run directly: ecs/tests/operator-complete.mutation.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../../scripts/lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the ECS operator-complete verb" "ecs/tests/operator-complete.test.sh"

A="ecs/adapters/app.py"

mutant replay-not-a-duplicate "O1 " "$A" \
    '    existing = store.existing_event(key){NL}    if existing:{NL}        if (existing["entity_id"] != context["entity_id"] or existing["thread_id"] != context["thread_id"]{NL}                or json.loads(existing["payload_json"]) != payload):' \
    '    existing = store.existing_event(key){NL}    if False:{NL}        if (existing["entity_id"] != context["entity_id"] or existing["thread_id"] != context["thread_id"]{NL}                or json.loads(existing["payload_json"]) != payload):' \
    "a host retry after a lost answer would be refused, and the notice would say the land failed."
mutant land-unverified "O2 " "$A" \
    '            _operator_git_verified(repo, branch, commit){NL}            continue' \
    '            continue' \
    "a report naming a commit that never reached the branch would close his assignment as landed."
mutant answer-digest-unchecked "O3 " "$A" \
    '                    or hashlib.sha256(text.encode("utf-8")).hexdigest() != answer.group(1)):' \
    '                    ):' \
    "an answer digest would close the assignment without the text it stands for."
mutant empty-evidence-accepted "O4 " "$A" \
    '            or any(not isinstance(e, str) or len(e) > 1024 for e in items) or len(set(items)) != len(items)):' \
    '            or any(not isinstance(e, str) or len(e) > 1024 for e in items) or len(set(items)) != len(items)) and items:' \
    "an assignment would be closed with no evidence at all."
mutant work-seat-allowed "O5 " "$A" \
    '    if not is_ceo_row(context):{NL}        raise ScopeError("operator completion belongs' \
    '    if False:{NL}        raise ScopeError("operator completion belongs' \
    "a background seat could certify its own completion."
mutant closed-closed-again "O6 " "$A" \
    '        if item["status"] not in OPERATOR_OPEN:' \
    '        if False:' \
    "a finished assignment could be re-closed with other evidence, rewriting what it was closed with."
mutant land-closes-a-failure "O7 " "$A" \
    '    if status == OPERATOR_WITHDRAWN and any(item.startswith("git:") for item in evidence):' \
    '    if False:' \
    "a failed assignment could be closed by citing a land."
mutant verb-unannounced "O8 " "$A" \
    '"complete-obligation", "operator-complete", "seats"' \
    '"complete-obligation", "seats"' \
    "the app would have to infer from a refusal whether this engine can close his assignments."

mutation_end
