def status(owner):
    if owner == "native":
        return "platform-pending"
    if owner == "external":
        return "verified"
    return "bound"
