"""CPU admission shared by proof runs, native work, devices and the watchdog.

Host utilization controls when new work starts. It does not authorize killing
an already admitted process; runaway detection is a separate per-process limit.
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
