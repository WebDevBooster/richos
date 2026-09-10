#!/usr/bin/env python3
"""G0 pty driver: runs the pinned Claude Code binary interactively in a pseudo-terminal, scripts keystrokes,
records every output chunk with a millisecond timestamp (raw + ANSI-stripped), and measures exit.
usage: ptydrive.py --out PREFIX --cwd DIR --steps STEPS.json -- <claude args...>
steps: {"expect": regex, "timeout": s} | {"send": text} | {"sleep": s} | {"waitfile": path, "timeout": s}
       | {"quiet": s, "timeout": s} | {"exit": "/exit"|"ctrlc"|"ctrld"|"hup"|"closepty", "timeout": s} | {"mark": label}
"""
import argparse, json, os, pty, re, select, signal, sys, time, fcntl, termios, struct

CURSOR_FWD = re.compile(rb'\x1b\[\d*C')
ANSI_RE = re.compile(rb'\x1b\[[0-9;?<>]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>78]|\r')
class _Ansi:
    @staticmethod
    def sub(_unused, data):
        return ANSI_RE.sub(b'', CURSOR_FWD.sub(b' ', data))
ANSI = _Ansi()

def now_ms(): return int(time.time()*1000)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True); ap.add_argument('--cwd', required=True)
    ap.add_argument('--steps', required=True); ap.add_argument('--cols', type=int, default=140)
    ap.add_argument('--rows', type=int, default=45); ap.add_argument('--global-timeout', type=int, default=600)
    ap.add_argument('args', nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cargs = [x for x in a.args if x != '--']
    steps = json.load(open(a.steps))
    env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC'))}
    env['TERM'] = 'xterm-256color'; env['COLUMNS'] = str(a.cols); env['LINES'] = str(a.rows)
    binary = '/Users/alex/.local/share/claude/versions/2.1.267'
    raw = open(a.out + '.raw', 'wb'); events = open(a.out + '.events.jsonl', 'w')
    stripped = bytearray(); t_start = now_ms()
    def ev(kind, **kw):
        kw.update(kind=kind, ts_ms=now_ms(), rel_ms=now_ms()-t_start); events.write(json.dumps(kw)+'\n'); events.flush()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(a.cwd)
        os.execve(binary, [binary] + cargs, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', a.rows, a.cols, 0, 0))
    ev('spawn', pid=pid, args=cargs)
    trusted = [False]; exited = [None]; last_out = [now_ms()]; fd_open = [True]
    def pump(timeout):
        if not fd_open[0]:
            time.sleep(timeout); return True
        r, _, _ = select.select([fd], [], [], timeout)
        if fd in r:
            try: data = os.read(fd, 65536)
            except OSError: data = b''
            if not data:
                return False
            raw.write(data); raw.flush(); last_out[0] = now_ms()
            s = ANSI.sub(b'', data); stripped.extend(s)
            events.write(json.dumps({'kind': 'out', 'ts_ms': now_ms(), 'rel_ms': now_ms()-t_start, 'n': len(data), 'text': s.decode('utf-8', 'replace')})+'\n'); events.flush()
            txt = bytes(stripped[-4000:]).decode('utf-8', 'replace')
            if not trusted[0] and re.search(r'trust\s*this\s*folder|Quick\s*safety\s*check|Yes,\s*proceed', txt):
                trusted[0] = True; time.sleep(0.6); os.write(fd, b'\x1b[B'); time.sleep(0.4); os.write(fd, b'\r'); ev('auto-trust-down-enter')
            return True
        return True
    def alive():
        if exited[0] is not None: return False
        try: p, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError: exited[0] = -1; return False
        if p == pid: exited[0] = st; ev('exit', status=st); return False
        return True
    def send(text):
        os.write(fd, text.encode()); ev('send', text=text)
    deadline = time.time() + a.global_timeout
    for st in steps:
        if time.time() > deadline: ev('global-timeout'); break
        if 'expect' in st:
            rx = re.compile(st['expect']); t_end = time.time() + st.get('timeout', 60); found = False; base = len(stripped)
            while time.time() < t_end and alive():
                pump(0.2)
                if rx.search(bytes(stripped[max(0, base-200):]).decode('utf-8', 'replace')): found = True; break
            ev('expect', pattern=st['expect'], found=found)
            if not found and st.get('required', True): ev('abort', reason='expect-not-found'); break
        elif 'send' in st:
            for _ in range(3): pump(0.1)
            send(st['send'])
        elif 'sleep' in st:
            t_end = time.time() + st['sleep']
            while time.time() < t_end and alive(): pump(0.2)
        elif 'waitfile' in st:
            t_end = time.time() + st.get('timeout', 120); ok = False
            while time.time() < t_end and alive():
                pump(0.2)
                if os.path.exists(st['waitfile']): ok = True; break
            ev('waitfile', path=st['waitfile'], found=ok)
        elif 'quiet' in st:
            t_end = time.time() + st.get('timeout', 120); ok = False
            while time.time() < t_end and alive():
                pump(0.2)
                if now_ms() - last_out[0] > st['quiet']*1000: ok = True; break
            ev('quiet', seconds=st['quiet'], reached=ok)
        elif 'mark' in st:
            ev('mark', label=st['mark'])
        elif 'shell' in st:
            import subprocess
            r = subprocess.run(['bash', '-c', st['shell']], capture_output=True, text=True)
            ev('shell', cmd=st['shell'], rc=r.returncode, out=r.stdout[-3000:], err=r.stderr[-500:])
        elif 'waitshell' in st:
            import subprocess
            t_end = time.time() + st.get('timeout', 120); ok = False
            while time.time() < t_end and alive():
                pump(0.3)
                r = subprocess.run(['bash', '-c', st['waitshell']], capture_output=True, text=True)
                if r.returncode == 0: ok = True; ev('waitshell', cmd=st['waitshell'], ok=True, out=r.stdout[-400:]); break
            if not ok: ev('waitshell', cmd=st['waitshell'], ok=False)
        elif 'exit' in st:
            how = st['exit']; t0 = now_ms(); ev('exit-request', how=how)
            if how == '/exit': send('/exit'); time.sleep(0.3); send('\r')
            elif how == 'ctrlc': send('\x03'); time.sleep(0.4); send('\x03')
            elif how == 'ctrld': send('\x04')
            elif how == 'hup': os.kill(pid, signal.SIGHUP)
            elif how == 'closepty': os.close(fd); fd_open[0] = False; ev('pty-closed')
            else: send(how)
            t_end = time.time() + st.get('timeout', 30)
            while time.time() < t_end and alive():
                pump(0.2)
            if exited[0] is None:
                ev('exit-timeout', after_ms=now_ms()-t0); os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); ev('sigkill')
            else:
                ev('exited', after_ms=now_ms()-t0, status=exited[0])
    if exited[0] is None:
        for _ in range(5): pump(0.2)
        if alive():
            ev('cleanup-sigkill'); os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
    open(a.out + '.txt', 'wb').write(bytes(stripped)); ev('done')

if __name__ == '__main__':
    main()
