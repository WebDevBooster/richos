#!/usr/bin/env bash
#
# provision-claude-md.sh — turn CLAUDE.md.template into a REAL CLAUDE.md at install time.
#
# THE PROBLEM THIS SOLVES. The engine ships `CLAUDE.md.template`, not `CLAUDE.md`. Claude Code only
# auto-loads `CLAUDE.md`, so a bare boot in this directory comes up as GENERIC CLAUDE — the Rich
# persona only ever gets established by the app's re-prime path
# (`app/crates/richos-core/src/reprime.rs:130-133` says exactly this). That is fragile (the persona
# depends on a runtime code path) and it is a bad first run for a self-installing CEO.
#
# WHAT IT DOES. Renders the template with the CEO's actuals from `identity.config`:
#   - injects a "Who you work for" section (company, CEO, product, loro pointer) after the persona;
#   - strips the adopter-facing header block (instructions ABOUT the file are not doctrine);
#   - replaces every `<!-- TODO (adopter) -->` block with either the configured value or an explicit,
#     honest "not configured yet — ask, do not assume" note. Adopter instructions NEVER survive into
#     the live doctrine file, and nothing is ever invented to fill a gap.
#
# IDEMPOTENT AND NO-CLOBBER. The generated file ends with a provenance stamp that carries the engine
# version, the template's sha256, the values' sha256 and the BODY's own sha256:
#
#   <!-- richos-provisioned: engine=1.0.0 template-sha256=… values-sha256=… body-sha256=… -->
#
# Identity baked inside the artifact, verified by the consumer — the same posture as the rest of the
# engine. On re-run: unchanged inputs => no-op; changed template/values with an UNEDITED file =>
# refreshed; a CEO-EDITED file => never touched (with --upgrade, the new render lands beside it as
# `CLAUDE.md.new` so UPGRADING.md's hand-apply step becomes mechanical instead of archaeological).
#
# USAGE
#   scripts/provision-claude-md.sh [--config F] [--template F] [--out F] [--upgrade] [--force]
#   scripts/provision-claude-md.sh --check          # write nothing; exit 1 if absent/stale
#   scripts/provision-claude-md.sh --print          # render to stdout, write nothing
#   scripts/provision-claude-md.sh --identity-json  # the CEO actuals as JSON (for other components)
#
# EXIT CODES
#   0  provisioned / refreshed / up-to-date / preserved
#   1  --check: CLAUDE.md is absent or stale
#   2  usage or configuration error (missing identity.config, blank required value, template drift)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$ENGINE_ROOT/identity.config"
TEMPLATE_FILE="$ENGINE_ROOT/CLAUDE.md.template"
OUT_FILE="$ENGINE_ROOT/CLAUDE.md"
MODE="write"
UPGRADE=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --template) TEMPLATE_FILE="$2"; shift 2 ;;
        --out) OUT_FILE="$2"; shift 2 ;;
        --check) MODE="check"; shift ;;
        --print) MODE="print"; shift ;;
        --identity-json) MODE="identity-json"; shift ;;
        --upgrade) UPGRADE=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ERROR: provision-claude-md.sh: unknown argument "%s"\n' "$1" >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || {
    printf 'ERROR: provision-claude-md.sh: python3 is required (rendering + sha256) — refusing\n' >&2
    exit 2
}

[ -f "$TEMPLATE_FILE" ] || {
    printf 'ERROR: provision-claude-md.sh: no template at %s — refusing\n' "$TEMPLATE_FILE" >&2
    exit 2
}

# --- values ---------------------------------------------------------------
# Every key the renderer understands, defaulted empty so `set -u` is safe and an unset key is simply
# an unconfigured one (honest note) rather than a crash.
COMPANY_NAME="" CEO_NAME="" COMPANY_DOMAIN="" COMPANY_ONE_LINER="" PRODUCT_NAME=""
CEO_TIMEZONE="" CEO_NOTES="" VCS_NOTES="" TEAM_ROSTER="" ROUTING_RULES="" EXTRA_DIRS=""
PRODUCT_SURFACES="" PRODUCT_HARD_RULES="" DEPLOY_TARGETS="" QA_ROLES="" LORO_PATH="../loro"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
elif [ "$MODE" != "identity-json" ]; then
    printf 'ERROR: provision-claude-md.sh: no identity config at %s\n' "$CONFIG_FILE" >&2
    printf '       Copy identity.config.example to identity.config and fill in COMPANY_NAME + CEO_NAME.\n' >&2
    exit 2
fi

if [ "$MODE" != "identity-json" ]; then
    missing=""
    [ -n "$COMPANY_NAME" ] || missing="$missing COMPANY_NAME"
    [ -n "$CEO_NAME" ] || missing="$missing CEO_NAME"
    if [ -n "$missing" ]; then
        printf 'ERROR: provision-claude-md.sh: required value(s) blank in %s:%s\n' "$CONFIG_FILE" "$missing" >&2
        printf '       Refusing to write a CLAUDE.md that says TODO where the company/CEO belongs.\n' >&2
        exit 2
    fi
fi

ENGINE_VERSION="$(cat "$ENGINE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -n "$ENGINE_VERSION" ] || ENGINE_VERSION="unknown"

export RP_COMPANY_NAME="$COMPANY_NAME" RP_CEO_NAME="$CEO_NAME" RP_COMPANY_DOMAIN="$COMPANY_DOMAIN"
export RP_COMPANY_ONE_LINER="$COMPANY_ONE_LINER" RP_PRODUCT_NAME="$PRODUCT_NAME"
export RP_CEO_TIMEZONE="$CEO_TIMEZONE" RP_CEO_NOTES="$CEO_NOTES" RP_VCS_NOTES="$VCS_NOTES"
export RP_TEAM_ROSTER="$TEAM_ROSTER" RP_ROUTING_RULES="$ROUTING_RULES" RP_EXTRA_DIRS="$EXTRA_DIRS"
export RP_PRODUCT_SURFACES="$PRODUCT_SURFACES" RP_PRODUCT_HARD_RULES="$PRODUCT_HARD_RULES"
export RP_DEPLOY_TARGETS="$DEPLOY_TARGETS" RP_QA_ROLES="$QA_ROLES" RP_LORO_PATH="$LORO_PATH"
export RP_ENGINE_VERSION="$ENGINE_VERSION" RP_TEMPLATE="$TEMPLATE_FILE" RP_OUT="$OUT_FILE"
export RP_MODE="$MODE" RP_UPGRADE="$UPGRADE" RP_FORCE="$FORCE"

python3 - <<'PY'
import hashlib, json, os, posixpath, re, sys

V = {k[3:]: os.environ.get(k, '') for k in os.environ if k.startswith('RP_')}
MODE, UPGRADE, FORCE = V['MODE'], V['UPGRADE'] == '1', V['FORCE'] == '1'
TEMPLATE, OUT = V['TEMPLATE'], V['OUT']

IDENTITY_KEYS = ['COMPANY_NAME', 'CEO_NAME', 'COMPANY_DOMAIN', 'COMPANY_ONE_LINER',
                 'PRODUCT_NAME', 'CEO_TIMEZONE', 'CEO_NOTES', 'LORO_PATH']

if MODE == 'identity-json':
    print(json.dumps({k.lower(): V.get(k, '') for k in IDENTITY_KEYS}, indent=2))
    sys.exit(0)

def sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()

STAMP_RE = re.compile(r'^<!-- richos-provisioned: .*-->\s*$', re.M)

# --- the honest "not configured" note -------------------------------------
def unset(statement, guidance):
    return ('> **Not configured for this installation.** ' + statement + ' ' + guidance
            + ' **Ask the CEO rather than assuming; never invent a value to fill this gap.**')

# Each TODO block in the template, keyed by a distinctive phrase from its own text, mapped to
# (config value, renderer). A block whose key is NOT in this table is TEMPLATE DRIFT and fails loud:
# leaking adopter instructions into Rich's live doctrine would be worse than refusing to provision.
def as_block(value, fallback):
    value = (value or '').strip()
    return value if value else fallback

BLOCKS = [
    ('version-control history',
     lambda: as_block(V['VCS_NOTES'], 'Nothing further to record: plain Git, no migration history, no banned commands.')),
    ('list your DOMAIN team',
     lambda: as_block(V['TEAM_ROSTER'],
                      unset('No domain team is staffed yet — only the working meta-roles above exist.', 'Run `skills/bootstrap-interview/SKILL.md`, or have Dean instantiate a role template, before delegating domain work.'))),
    ('state your routing rules',
     lambda: as_block(V['ROUTING_RULES'],
                      'Until a domain team is staffed: research goes to Clark, source-reading to Reed, '
                      'stress-testing a plan to Frank, and hiring a missing role to Dean. Anything else is '
                      'yours to do as the CEO\'s COO within your three reserved exceptions, or to escalate.')),
    ('additional repo-root directories',
     lambda: as_block(V['EXTRA_DIRS'], '')),
    ('more than one user-facing surface',
     lambda: as_block(V['PRODUCT_SURFACES'],
                      unset('No surface map is recorded.', 'Treat the product as a single surface until told otherwise, and confirm the surface before ANY user-facing work.'))),
    ('analogous deploy/device',
     lambda: 'Not adopted for this installation — the advanced tier ships as reference in `reference/advanced-tier/`.'),
    ('device/install-fresh render pipeline',
     lambda: 'Not adopted for this installation — the advanced tier ships as reference in `reference/advanced-tier/`.'),
    ('this heading is ALREADY your real one',
     lambda: as_block(V['PRODUCT_HARD_RULES'],
                      unset('No product hard rules are recorded.', 'A hard rule is a non-negotiable invariant, so it comes from the CEO, never from you.'))),
    ('define your deploy targets',
     lambda: as_block(V['DEPLOY_TARGETS'],
                      unset('No deploy target is configured.', 'The deploy-always rule above stands the moment one exists: what is on `main` MUST be what is on staging.'))),
    ('map each of the four steps',
     lambda: as_block(V['QA_ROLES'],
                      unset('No QA teammates are staffed yet.', 'The four bars above stand exactly as written; staff the roles via Dean before any code change goes through the pipeline.'))),
]

def render_block(body):
    key = ' '.join(body.split())
    for needle, fn in BLOCKS:
        if needle.lower() in key.lower():
            return fn()
    print('ERROR: provision-claude-md.sh: unrecognized TODO block in the template — refusing to render.\n'
          '       Block text: ' + key[:160] + '\n'
          '       The template changed; teach this script the new block before provisioning.', file=sys.stderr)
    sys.exit(2)

def identity_section():
    lines = ['## Who you work for', '']
    lines.append('- **CEO:** ' + V['CEO_NAME'])
    company = V['COMPANY_NAME']
    if V['COMPANY_DOMAIN']:
        company += ' (' + V['COMPANY_DOMAIN'] + ')'
    lines.append('- **Company:** ' + company)
    if V['COMPANY_ONE_LINER']:
        lines.append('- **What the company does:** ' + V['COMPANY_ONE_LINER'])
    if V['PRODUCT_NAME']:
        lines.append('- **Product:** ' + V['PRODUCT_NAME'])
    if V['CEO_TIMEZONE']:
        lines.append('- **CEO time zone:** ' + V['CEO_TIMEZONE'])
    if V['LORO_PATH']:
        # The corpus root is REQUIRED and explicit — loro has no default root, because a default root
        # means answering out of the vendor's company memory and exiting 0. `--root <repo>` is the
        # in-repo case; a CEO with a provisioned corpus outside the repo uses `--corpus <dir>`.
        loro_root = posixpath.dirname(V['LORO_PATH'].rstrip('/')) or '.'
        lines.append('- **Company memory (loro):** `' + V['LORO_PATH'] + '` — compile the slice that bears on '
                     'the task before answering from general knowledge: '
                     '`node ' + V['LORO_PATH'] + '/bin/loro-context.mjs compile --root ' + loro_root +
                     ' --topic "<the active thread>"`. '
                     'A thin slice means loro does not know — ask, never invent. loro REFUSES to run without '
                     'an explicit corpus root (`--root <repo>`, or `--corpus <dir>` / `LORO_CORPUS` once the '
                     'CEO\'s corpus lives outside the repo) — that refusal is the guarantee you are reading '
                     'HIS memory and not somebody else\'s. When you hand work to a teammate, compile their '
                     'slice with `--audience worker`: CEO-private memory is never theirs to see.')
    if V['CEO_NOTES']:
        lines += ['', V['CEO_NOTES'].strip()]
    lines += ['', 'These are facts about who you serve, not preferences to be re-derived. Everything below is '
                  'your operating doctrine.']
    return '\n'.join(lines)

src = open(TEMPLATE, encoding='utf-8').read()
template_sha = sha(src)
values_sha = sha('\n'.join(k + '=' + V.get(k, '') for k in sorted(
    ['COMPANY_NAME', 'CEO_NAME', 'COMPANY_DOMAIN', 'COMPANY_ONE_LINER', 'PRODUCT_NAME', 'CEO_TIMEZONE',
     'CEO_NOTES', 'VCS_NOTES', 'TEAM_ROSTER', 'ROUTING_RULES', 'EXTRA_DIRS', 'PRODUCT_SURFACES',
     'PRODUCT_HARD_RULES', 'DEPLOY_TARGETS', 'QA_ROLES', 'LORO_PATH'])))

# 1. Drop the adopter-facing header comment block — instructions ABOUT the file are not doctrine.
body = re.sub(r'\A<!--\s*=+.*?=+\s*-->\s*', '', src, count=1, flags=re.S)

# 2. Replace every adopter TODO block with a configured value or an honest unset note.
body = re.sub(r'<!--\s*TODO \(adopter\):(.*?)-->', lambda m: render_block(m.group(1)), body, flags=re.S)

# 3. The pagination sample bullet is a placeholder living OUTSIDE its comment — swap it too, so no
#    sample rule is ever mistaken for this company's real doctrine.
sample = re.compile(r'^\*\*No pagination — ever\.\*\*.*?$\n', re.M)
if sample.search(body):
    rules = (V['PRODUCT_HARD_RULES'] or '').strip()
    body = sample.sub((rules + '\n') if rules else '', body, count=1)

# 4. Inject the identity section directly after the persona blockquote.
anchor = '> **If the CEO has to manage the AI workers, Rich has failed.**'
if anchor not in body:
    print('ERROR: provision-claude-md.sh: persona anchor not found in the template — refusing.', file=sys.stderr)
    sys.exit(2)
body = body.replace(anchor, anchor + '\n\n' + identity_section(), 1)

body = re.sub(r'\n{3,}', '\n\n', body).strip() + '\n'
body_sha = sha(body)
stamp = ('<!-- richos-provisioned: engine=' + V['ENGINE_VERSION'] + ' template-sha256=' + template_sha[:16]
         + ' values-sha256=' + values_sha[:16] + ' body-sha256=' + body_sha[:16] + ' -->')
rendered = body + '\n' + stamp + '\n'

if MODE == 'print':
    sys.stdout.write(rendered)
    sys.exit(0)

def read_existing():
    try:
        return open(OUT, encoding='utf-8').read()
    except OSError:
        return None

existing = read_existing()

def classify(existing_text):
    """(state, detail) for an existing CLAUDE.md: absent | hand-authored | edited | stale | current."""
    if existing_text is None:
        return 'absent', ''
    m = None
    for m in STAMP_RE.finditer(existing_text):
        pass
    if m is None:
        return 'hand-authored', 'no provisioning stamp'
    # The stamp must be the LAST content in the file. Anything after it is the CEO's own text —
    # without this check an appended edit would sit outside the hashed body and read as unmodified.
    if existing_text[m.end():].strip():
        return 'edited', 'content added after the provisioning stamp'
    old_body = existing_text[:m.start()].rstrip('\n') + '\n'
    fields = dict(kv.split('=', 1) for kv in m.group(0).split() if '=' in kv)
    if fields.get('body-sha256') != sha(old_body)[:16]:
        return 'edited', 'body no longer matches its stamp'
    if fields.get('template-sha256') != template_sha[:16] or fields.get('values-sha256') != values_sha[:16]:
        return 'stale', 'template or identity values changed since generation'
    return 'current', ''

state, detail = classify(existing)

if MODE == 'check':
    if state == 'current':
        print('up-to-date: ' + OUT)
        sys.exit(0)
    print('NOT PROVISIONED (' + state + (': ' + detail if detail else '') + '): ' + OUT, file=sys.stderr)
    sys.exit(1)

if state == 'current' and not FORCE:
    print('up-to-date: ' + OUT + ' (engine ' + V['ENGINE_VERSION'] + ')')
    sys.exit(0)

if state in ('edited', 'hand-authored') and not FORCE:
    # NEVER clobber the CEO's own words. Offer the new render alongside instead.
    msg = 'preserved: ' + OUT + ' was edited by hand (' + detail + ') — NOT overwritten.'
    if UPGRADE:
        with open(OUT + '.new', 'w', encoding='utf-8') as fh:
            fh.write(rendered)
        msg += '\n          new render written to ' + OUT + '.new — diff and hand-apply (see UPGRADING.md).'
    else:
        msg += '\n          re-run with --upgrade to write the new render beside it as CLAUDE.md.new.'
    print(msg)
    sys.exit(0)

with open(OUT, 'w', encoding='utf-8') as fh:
    fh.write(rendered)
verb = {'absent': 'provisioned', 'stale': 'refreshed', 'current': 'rewritten',
        'edited': 'OVERWRITTEN (--force)', 'hand-authored': 'OVERWRITTEN (--force)'}[state]
print(verb + ': ' + OUT + ' (engine ' + V['ENGINE_VERSION'] + ', template ' + template_sha[:16] + ')')
PY
