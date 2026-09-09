def status(owner):
    """Return the lifecycle status for an owner.

    Current approved contract (requirements.md):
      - native   -> "platform-pending"
      - external -> "verified"

    Owners outside the approved contract keep the pre-existing
    "bound" fallback; requirements.md does not specify them.
    """
    if owner == "native":
        return "platform-pending"
    if owner == "external":
        return "verified"
    return "bound"
