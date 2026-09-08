"""Daily idle admission for the ordinary-user cleanup job.

The calendar trigger and login catch-up share a durable local-date receipt.
Waiting checks only HID idle time, never repository contents.
"""
from datetime import datetime, timedelta
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import time
import tempfile


def due_slot(now, hour):
    day = now.date() if now.hour >= hour else now.date() - timedelta(days=1)
    return day.isoformat()


def idle_seconds():
    result = subprocess.run(['/usr/sbin/ioreg', '-a', '-r', '-c', 'IOHIDSystem'],
                            capture_output=True, check=True, timeout=10)
    values = [row['HIDIdleTime'] for row in plistlib.loads(result.stdout)
              if isinstance(row, dict) and 'HIDIdleTime' in row]
    if not values or any(type(v) is not int or v < 0 for v in values):
        raise ValueError('native user idle time unavailable')
    return min(values) / 1_000_000_000


def state_path():
    # Follow the transaction store in fixtures and redirected installations.
    tx = os.environ.get('RICHOS_WORKTREE_TX_DIR')
    root = Path(tx).expanduser().parent if tx else Path(os.environ.get(
        'CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / 'state'
    return root / 'worktree-cleanup-schedule.json'


def scheduled(action, hour=4, idle_minutes=10, *, path=None,
              now=datetime.now, idle=idle_seconds, sleep=time.sleep):
    if not 0 <= hour <= 23 or not math.isfinite(idle_minutes) or idle_minutes <= 0:
        raise ValueError('invalid daily cleanup schedule')
    path = Path(path) if path is not None else state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path = path.parent.resolve() / path.name
    lock = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 'already-running'
        last = None
        if path.exists():
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'r') as stream:
                record = json.load(stream)
            if record.get('version') != 1:
                raise ValueError('unsupported cleanup schedule receipt')
            last = record['last_completed_slot']
            datetime.strptime(last, '%Y-%m-%d')
        while True:
            slot = due_slot(now(), hour)
            if last is not None and last >= slot:
                return 'not-due'
            try:
                seconds = idle()
                ready = math.isfinite(seconds) and seconds >= idle_minutes * 60
            except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
                ready = False
            if ready:
                break
            sleep(60)
        # Each filesystem operation keeps its existing ownership and delivery checks.
        # If activity resumes, finish the current atomic step and defer the next one.
        def still_idle():
            try:
                seconds = idle()
                return math.isfinite(seconds) and seconds >= idle_minutes * 60
            except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
                return False
        if action(still_idle) is False:
            # Activity interrupted this pass; remain overdue for the next idle period.
            return 'interrupted'
        raw = json.dumps({'version': 1, 'last_completed_slot': due_slot(now(), hour)}) + '\n'
        fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
        with os.fdopen(fd, 'w') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
        return 'completed'
    finally:
        os.close(lock)
