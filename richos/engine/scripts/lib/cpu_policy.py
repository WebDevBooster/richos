"""CPU admission shared by proof runs, native work, devices and the watchdog.

Host utilization controls admission. Managed verification additionally uses
owned-tree measurements and an ordered pressure/recovery policy. These pure
decisions never authorize a signal without the controller's ownership check.
"""
import math

DEFAULT_MAX_CPU = 80


def busy_percent(sample):
    """reserve's user field includes nice time; add system time exactly once."""
    busy = sample['cpu_user_percent'] + sample['cpu_system_percent']
    if not math.isfinite(busy) or busy < 0:
        raise BlockingIOError('total CPU measurement unavailable')
    return busy


def admission_open(busy, limit=DEFAULT_MAX_CPU):
    return math.isfinite(busy) and 0 <= busy < limit


class VerificationPressure:
    """One host episode, independent of individual runner lifetimes.

    At ten seconds close new heavy/nested expansion. Existing borrowed permits
    can finish. With no qualified live-concurrency reducer, request containment
    by twenty seconds. Wait for owned cleanup, then reassess one contributor at
    a time. Ten consecutive healthy seconds are needed before reopening.
    The controller persists each cancellation's separate per-input budget.
    """
    def __init__(self):
        self.pressure_since = None
        self.recovery_since = None
        self.closed = False
        self.pending = None
        self.pending_since = None
        self.reassess_at = 0

    @staticmethod
    def contributor(owners, memory=False):
        metric = "rss_mb" if memory else "cores"
        candidates = [(key, owner) for key, owner in owners.items()
                      if math.isfinite(owner.get(metric, 0)) and owner.get(metric, 0) > 0]
        if not candidates:
            return None
        # Do not interrupt a dependency explicitly needed to release integration
        # capacity while an alternative contributor exists.
        independent = [row for row in candidates if not row[1].get("unblocks_integration")]
        candidates = independent or candidates
        background = [row for row in candidates if row[1].get("priority") != "integration"]
        candidates = background or candidates
        # Choose among substantial contributors, then lose the least measured
        # work. PID age/order is not a resource policy.
        largest = max(owner[metric] for _, owner in candidates)
        candidates = [row for row in candidates if row[1][metric] >= largest / 2]
        return min(candidates, key=lambda row: (row[1].get("cpu_seconds", 0), -row[1][metric], str(row[0])))[0]

    def observe(self, now, busy, owners, memory_pressure="normal", swapout_mb_per_s=0):
        valid = math.isfinite(busy) and busy >= 0 and math.isfinite(swapout_mb_per_s)
        memory = memory_pressure == "critical" or swapout_mb_per_s >= 16
        pressure = not valid or busy >= DEFAULT_MAX_CPU or memory
        result = {"admission_open": not self.closed, "stage": "normal", "target": None}
        if pressure:
            self.recovery_since = None
            if self.pressure_since is None:
                self.pressure_since = now
            if now - self.pressure_since >= 10 or not valid:
                self.closed = True
        else:
            self.pressure_since = None
            if self.recovery_since is None:
                self.recovery_since = now
            if self.pending is None and now - self.recovery_since >= 10:
                self.closed = False
        if self.pending is not None:
            if self.pending in owners:
                result.update(stage="containment-failed" if now - self.pending_since >= 30 else "cleanup",
                              target=self.pending)
            else:
                self.pending = self.pending_since = None
                self.reassess_at = now + 10
        if self.pending is None and self.closed:
            result["stage"] = "recovery" if not pressure else "admission-closed"
            if pressure and self.pressure_since is not None and now >= max(self.pressure_since + 20, self.reassess_at):
                # Unknown host attribution cannot authorize arbitrary cancellation.
                target = self.contributor(owners, memory) if valid else None
                result.update(stage="contain" if target is not None else "unattributed-pressure", target=target)
                if target is not None:
                    self.pending, self.pending_since = target, now
        result["admission_open"] = not self.closed and valid and not pressure
        return result
