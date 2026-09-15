#!/usr/bin/env python3
"""Compatibility entry point for Mega Lander; supports imports and CLI use."""
from pathlib import Path as _Path

_impl = (_Path(__file__).resolve().parent / "../mega-lander/workspace-probes.py").resolve()
__file__ = str(_impl)
__doc__ = None
exec(compile(_impl.read_bytes(), __file__, "exec"), globals(), globals())
