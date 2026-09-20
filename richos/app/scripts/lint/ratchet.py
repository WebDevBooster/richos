"""Read-only checks against a committed ceiling and its integration ancestor.

Counts prevent net growth, not every new violation: fix one and add one can
leave a count unchanged. Baseline migration is explicit, never a check side effect.
"""
import json
from common import Refusal, checked

NOTE = "Counts prevent net growth, not every new violation. Check never writes."


def validate(record):
    if not isinstance(record, dict) or record.get("schema") != 1 or record.get("limitation") != NOTE:
        raise Refusal("invalid lint baseline schema")
    for field in ("commands", "versions", "rules", "inventory", "counts"):
        if not isinstance(record.get(field), dict) or not record[field]:
            raise Refusal(f"missing or empty baseline {field}")
    if any(type(n) is not int or n < 0 for n in record["counts"].values()):
        raise Refusal("invalid lint ceiling")


def compare(candidate, trusted):
    """A candidate cannot silently weaken the baseline already on integration."""
    validate(candidate)
    validate(trusted)
    for key in ("commands", "versions"):
        if candidate[key] != trusted[key]:
            raise Refusal(f"baseline {key} changed; requires an explicit integration migration")
    for rule, severity in trusted["rules"].items():
        if candidate["rules"].get(rule) != severity:
            raise Refusal(f"removed or weakened rule: {rule}")
    for path, role in trusted["inventory"].items():
        if candidate["inventory"].get(path) != role:
            raise Refusal(f"shrunk or reclassified inventory: {path}")
    for rule, ceiling in trusted["counts"].items():
        if rule not in candidate["counts"] or candidate["counts"][rule] > ceiling:
            raise Refusal(f"removed or raised ceiling: {rule}")
    for rule, ceiling in candidate["counts"].items():
        if rule not in trusted["counts"] and ceiling:
            raise Refusal(f"new nonzero ceiling: {rule}")


def check(actual, baseline):
    validate(baseline)
    for field in ("commands", "versions", "rules"):
        if actual[field] != baseline[field]:
            raise Refusal(f"lint {field} do not match the committed baseline")
    # New files must be scanned even before explicitly adding their inventory.
    for path, role in baseline["inventory"].items():
        if actual["inventory"].get(path) != role:
            raise Refusal(f"shrunk or reclassified scan inventory: {path}")
    for rule, count in actual["counts"].items():
        ceiling = baseline["counts"].get(rule, 0)
        if count > ceiling:
            raise Refusal(f"lint growth: {rule}: {count} > {ceiling}")


def lower(actual, baseline):
    check(actual, baseline)
    proposed = dict(baseline)
    proposed["inventory"] = actual["inventory"]
    proposed["counts"] = {key: actual["counts"].get(key, 0) for key in baseline["counts"]}
    for key, value in actual["counts"].items():
        proposed["counts"].setdefault(key, value)
    return proposed


def trusted_record(root, reference, path):
    # The reference must resolve. Absence on an existing integration revision is
    # the initial introduction, not permission to ignore a broken reference.
    revision = checked(["git", "rev-parse", "--verify", reference + "^{commit}"], root).strip()
    existing = checked(["git", "ls-tree", "--name-only", revision, "--", path], root).strip()
    if not existing:
        return None
    try:
        return json.loads(checked(["git", "show", revision + ":" + path], root))
    except ValueError as exc:
        raise Refusal("malformed integration lint baseline") from exc
