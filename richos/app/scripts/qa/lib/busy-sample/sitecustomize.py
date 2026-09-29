"""Loaded only under ../../busy-sample.py, which puts this directory first on PYTHONPATH.

Every admission sample `scripts/testvm/reserve.py` takes in this process then reads
RICHOS_QA_BUSY_PERCENT busy, with memory pressure normal and no swap-out. reserve.py reads the
kernel through libSystem (`host_statistics` for CPU ticks, `host_statistics64` for swap-outs,
`sysctlbyname` for the pressure level); those three answers are replaced after the real call
succeeds, and every other call goes to libSystem unchanged. Without the variable this file
does nothing.
"""
import ctypes
import os

try:
    _BUSY = float(os.environ["RICHOS_QA_BUSY_PERCENT"])
except (KeyError, ValueError):
    _BUSY = None

HOST_CPU_LOAD_INFO = 3
HOST_VM_INFO64 = 4
PRESSURE_NORMAL = 1


class _Library:
    """libSystem, with reserve.py's three admission readings fixed."""

    def __init__(self, library):
        object.__setattr__(self, "_library", library)
        object.__setattr__(self, "_ticks", 0)

    def __setattr__(self, name, value):
        setattr(self._library, name, value)

    def __getattr__(self, name):
        real = getattr(self._library, name)
        if name == "host_statistics":
            def host_statistics(host, flavor, info, count):
                result = real(host, flavor, info, count)
                if flavor == HOST_CPU_LOAD_INFO and result == 0:
                    ticks = self._ticks + 1000
                    object.__setattr__(self, "_ticks", ticks)
                    busy = int(round(ticks * _BUSY / 100.0))
                    load = info._obj
                    load.ticks[0], load.ticks[1], load.ticks[2], load.ticks[3] = busy, 0, ticks - busy, 0
                return result
            return host_statistics
        if name == "host_statistics64":
            def host_statistics64(host, flavor, info, count):
                result = real(host, flavor, info, count)
                if flavor == HOST_VM_INFO64 and result == 0:
                    info._obj.swapouts = 0
                return result
            return host_statistics64
        if name == "sysctlbyname":
            def sysctlbyname(key, value, size, new, new_size):
                result = real(key, value, size, new, new_size)
                if result == 0 and key == b"kern.memorystatus_vm_pressure_level":
                    value._obj.value = PRESSURE_NORMAL
                return result
            return sysctlbyname
        return real


if _BUSY is not None:
    _CDLL = ctypes.CDLL

    def CDLL(name, *args, **kwargs):
        library = _CDLL(name, *args, **kwargs)
        return _Library(library) if name and "libSystem" in str(name) else library

    ctypes.CDLL = CDLL
