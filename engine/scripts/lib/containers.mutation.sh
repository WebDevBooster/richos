#!/usr/bin/env bash
#
# containers.mutation.sh — PROVES the container suite CAN FAIL, one property at
# a time. Invoked by containers.test.sh; the loop is mutation-harness.sh.
#
# Every mutant removes ONE property from the SHIPPED source in a throwaway copy
# of the engine and names the case that must go red. The two that matter most
# are the two directions of the same asymmetry:
#
#   reap-does-nothing      — residue would survive a land (the founder's whole
#                            question), and D1 must catch it.
#   mount-authorizes-delete — a bind mount would authorize deletion, and D4
#                            must catch it. That is the mutant that would
#                            destroy somebody's running container, so a suite
#                            that stayed green under it would be worthless.
#
# The D cases need Docker. Where Docker is absent they SKIP, a skip is not a
# pass, and a mutant whose only witness skipped reports that it could not be
# proven rather than claiming it was — see _docker_or_skip below.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"

C="scripts/lib/containers.py"
W="scripts/lib/workspaces.py"

# A mutant whose witness is a D case proves nothing when Docker is not there,
# and saying so is the point: the alternative is a harness that reports every
# property load-bearing on a machine that never ran them.
DOCKER_OK=0
if docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
   && docker image inspect "${RICHOS_CONTAINER_TEST_IMAGE:-alpine:latest}" >/dev/null 2>&1; then
    DOCKER_OK=1
fi

mutation_begin "containers.py (container residue at the lifecycle)" "scripts/lib/containers.test.sh"

# --- proven on any machine -------------------------------------------------

mutant compose-label-ignored "test_C2_compose_working_dir_is_a_declaration" "$C" \
    '    compose_dir = (labels.get(COMPOSE_DIR_LABEL) or "").strip()' \
    '    compose_dir = ""' \
    "Compose's working_dir would stop being read, and every historical container on the machine would become unattributable — it is the ONLY signal that attributes agent-af36c9abcc76937ab-redis-1 to its agent."

mutant mount-authorizes-delete-unit "test_C3_a_bind_mount_never_authorizes_deletion" "$C" \
    '        if kind in ("label", "compose"):{NL}            return path, kind' \
    '        if kind in ("label", "compose", "mount"):{NL}            return path, kind' \
    "a bind mount would authorize DELETION rather than only protection, so a container a person started against a checkout by hand would be destroyed when that checkout landed."

mutant no-protection-for-live "test_C4_but_a_bind_mount_does_protect" "$C" \
    '        for path, kind in claims:{NL}            if any(_within(path, w) for w in live):' \
    '        for path, kind in []:{NL}            if any(_within(path, w) for w in live):' \
    "a container owned by a LIVE workspace would stop being recognized as protected — the four containers of another engineer's running work tonight."

mutant unowned-not-reported "test_C5_no_evidence_at_all_is_reported_and_never_touched" "$C" \
    '        else:{NL}            unowned.append(dict(c, owner=None, evidence=None))' \
    '        else:{NL}            pass' \
    "a container with no ownership evidence would vanish from the report, so residue nobody can attribute would stop being visible at all."

mutant docker-absence-raises "test_C8_docker_absent_is_never_a_failure" "$C" \
    '    except FileNotFoundError:{NL}        return False, "", "docker is not installed"' \
    '    except FileNotFoundError:{NL}        raise' \
    "a machine without Docker would raise out of the workspace deleter, so tidying up would break the land it is attached to."

mutant empty-paths-means-everything "test_C9_reap_with_no_paths_does_nothing" "$C" \
    '        if not paths:{NL}            result["reason"] = "no workspace paths given"{NL}            return result' \
    '        if False:{NL}            result["reason"] = "no workspace paths given"{NL}            return result' \
    "a caller passing no paths would fall through to the sweep instead of stopping, and 'nothing named' must never widen into 'everything'."

# --- proven only where Docker is present -----------------------------------

if [ "$DOCKER_OK" = "1" ]; then
    mutant reap-does-nothing "test_D1_a_landed_workspace_takes_its_container_with_it" "$W" \
        '        stop_containers([w["path"] for w in workspaces])' \
        '        pass' \
        "THE FOUNDER'S QUESTION. The lifecycle would stop reaping containers, and residue would again depend on somebody remembering to tidy up."

    # The witness here is D6, not D2, and the difference is the whole reason
    # this mutant exists. D2's live workspace is protected by never being a
    # TARGET, so emptying the liveness set leaves D2 green — the harness said
    # so, and that is how the footgun was found: a hand-run reap aimed AT a
    # live workspace had nothing stopping it. `ending` now separates the
    # deleter from everyone else, and D6 is what holds that separation up.
    mutant reap-ignores-liveness "test_D6_a_hand_run_reap_aimed_at_a_live_workspace_removes_nothing" "$C" \
        '        if ending:{NL}            # The deleter'"'"'s own workspaces are exempt from their own liveness:' \
        '        if True:{NL}            # The deleter'"'"'s own workspaces are exempt from their own liveness:' \
        "every caller would get the deleter's exemption, so a reap typed by hand at a workspace somebody is still working in would destroy its containers."

    mutant mount-authorizes-delete-real "test_D4_a_mounted_only_container_is_spared_at_its_mounts_land" "$C" \
        '        if kind in ("label", "compose"):{NL}            return path, kind' \
        '        if kind in ("label", "compose", "mount"):{NL}            return path, kind' \
        "with a REAL container and a REAL land: a bind-mounted container would be destroyed when the directory it mounts is landed."

    mutant auto-land-does-not-reap "test_D5_the_automatic_land_at_the_next_spawn_reaps_too" "$W" \
        '        stop_containers([w["path"] for w in workspaces])' \
        '        pass' \
        "the automatic land at the next spawn would leave containers behind, so reaping would only happen when somebody typed a command."
else
    printf '  SKIP  four mutants (reap-does-nothing, reap-ignores-liveness,\n'
    printf '        mount-authorizes-delete-real, auto-land-does-not-reap) — their\n'
    printf '        witnesses are the D cases and Docker is not available here, so\n'
    printf '        those properties are UNPROVEN on this machine rather than proven.\n'
fi

mutation_end
