#!/usr/bin/env python3
"""output-walk.py — the output record's three witnesses on the real app (Output side panel S2).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      output-walk.py --out DIR --expect-sha SHA [--within SECONDS]

run-walk.py passes the owned VM name as the first argument. `--steps a,b,c` runs a subset, still
as one run under run-walk.py. The engine must be packed from the same tree as the app
(`make-engine-asset.sh`): witnesses (b) and (c) live in the engine's `app-evidence.py`.

THE QUESTION. The Output side panel PRD's slice S2 (its §12.2, in the private record) asks for
one real-app check of each witness: a PDF that `pandoc` made is listed without Rich naming its
path; a back-end worker's file is listed under that worker; a front-desk worker's file is listed
under that worker, not under Rich. There is no panel yet (slice S4), so this reads what the panel
will read: the record, `<data>/output/<thread>.jsonl`, in the guest.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity           the running app says it was built from --expect-sha
  first-run          adopt-walk.py's: company "Acme" with a folder that is a Git repository
  connect            command-walk.py's: that folder connected as a repository
  tools              pandoc and typst (pandoc's PDF engine) installed in the guest with Homebrew
  pdf                typed: write a Markdown file in the Acme folder and make a PDF of it with
                     pandoc. PASS when a row for the PDF is in the record with source `command`.
                     Rich's words on this thread and the assignment's notices are checked for the
                     PDF's absolute path, and whether they carry it is reported.
  backend-worker     typed: add notes.md to the Acme repository, make notes.zip from it with git
                     archive in the same folder, commit both and land them. PASS when a row with
                     actor `worker` and a worker name is in the record, no row for that file says
                     `rich`, and (slice S2b) after the job settles both files are in the Acme folder,
                     each has a land row at the Acme path from the worker's worktree, notes.zip's
                     worktree row is a command row with the worker's agent id, and the list folded
                     by the §4.3 rule names each file once at the Acme path with nothing missing.
                     Approve is pressed when the work panel asks.
  front-desk-worker  typed: use your own Agent tool, in this turn, to start a worker that writes a
                     file. One attempt, recorded as it happens: whether the front desk called
                     Agent, what the app hook did with it (the callbacks of its session), whether
                     a file was written and by whom, and the record's rows for it. PASS when no
                     row attributes a worker's write to Rich.

  open-reveal        slice S3's real-app check (§12.3), run alone and with no app launched:
                       run-walk.py --no-app --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
                           output-walk.py --out DIR --expect-sha SHA --steps open-reveal --probe PROBE
                     PROBE is `examples/output_files_probe` built from the same tree. There is no
                     button for output_open or output_reveal until slice S4 builds the panel, so the
                     probe calls the very functions those commands call. The guest image has no app
                     for Markdown, so the step first makes TextEdit its handler (MARKDOWN_HANDLER,
                     recorded in the evidence). Then it records a
                     Markdown file it wrote as one witnessed write, opens it by its output id (the
                     default app), screenshots, shows it in Finder by the same id, screenshots.
                     PASS when both say what they did, the default app has a window named for the
                     file and Finder has one named for its folder. Finder's selection is seen in the
                     second screenshot: the guest grants no Apple Events to Finder to read it.

  panel              slice S4's real-app check (§12.4), after identity, first-run and connect:
                       --steps identity,first-run,connect,panel
                     typed: a shell command writes panel-check.md in the Acme folder. When its row
                     is in the record, the button named "Output — 1 file from this thread" is
                     pressed, the panel's Close and the file's row are found by name, and the list
                     is photographed; the guest's appearance is flipped (the app follows the OS on
                     a fresh install), photographed again, and put back. PASS when all of it holds.

  save-copy          slice S6's real-app check (§12.6), after the panel step:
                       --steps identity,first-run,connect,panel,save-copy
                     on the panel's one file: its row's More actions, Save a copy…, and the system
                     save sheet that opens on the app's window. The sheet must offer the file's own
                     name; the walk gives it SAVE_AS instead, reads its Where folder, presses Save.
                     PASS when exactly one file named SAVE_AS exists in the guest, in the folder the
                     sheet named, with the recorded file's bytes, and the panel's notice says so.
                     Both moments are photographed (save-copy-1-sheet.png, save-copy-2-saved.png).

Exit 0 when every step passes. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest  # noqa: E402

_spec = importlib.util.spec_from_file_location('command_walk', HERE / 'command-walk.py')
command_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(command_walk)
StepFailed = command_walk.StepFailed
command = command_walk.command

STEPS = ['identity', 'first-run', 'connect', 'tools', 'pdf', 'backend-worker', 'front-desk-worker', 'open-reveal', 'panel',
         'save-copy']
# S4's one written file: a shell command, so no tool needs installing and witness (c) sees it.
PANEL_TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme folder, '
              "and tell me when it has finished: printf '# Panel check\\n\\nOne written file.\\n' > panel-check.md")
# Every word of each file is given, so nothing has to be known about Acme: the first run of this
# walk asked for "two sentences about the Acme launch", and Rich rightly asked what they should say
# instead of making them up (stop_reason question_asked, no assignment).
# Worded as command-walk.py's TASK, the form proven to reach the back end as a task it carries out.
# Absolute paths: the second run's back end looked for pandoc on its PATH, missed Homebrew's
# /opt/homebrew/bin, and stopped to ask instead of running it.
PDF_TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme folder, '
            "and tell me when it has finished: printf '# Acme launch brief\\n\\nDraft for the walk test.\\n' > "
            'launch-brief.md && /opt/homebrew/bin/pandoc launch-brief.md -o launch-brief.pdf '
            '--pdf-engine=/opt/homebrew/bin/typst')
APPROVALS = 6
# Slice S2b (PRD §12.2b): the worker also makes a file with a command in its own worktree, which
# is under the app's data directory, and both files are landed. The PRD names pandoc; a WORKER's
# pandoc call needs his approval, and on the VM that approval never reached the Approve control
# (walks 4 and 5, 2026-10-05, esc-20261005T150541Z-ee581ad7), so the job never landed. A worker's
# git commands run unasked, so the command-made file is a git archive of the committed notes.md.
WORKER_TASK = ('Please add a file named notes.md whose whole content is the line "Notes for the walk test." '
               'to the Acme repository and commit it. Then, in the same folder, make notes.zip from that commit '
               'with the shell command git archive -o notes.zip HEAD notes.md, commit notes.zip too, '
               'and land both files.')
WORKTREES = '/engine-state/target-worktrees/'
MADE = 'notes.zip'
FRONT_DESK_TASK = ('This is a test of your own Agent tool. Do not register an assignment for it. In this turn, '
                   'use your Agent tool yourself to start one worker that writes a file named direct.md '
                   'containing the word direct in my Acme folder.')
OPEN = command_walk.OPEN
# The guest image has no app for Markdown: a fresh macOS maps `.md` to a type nothing claims, so
# Finder draws a blank icon and `open` has nothing to open it with (seen on the first S3 walk,
# 2026-10-05). The CEO's Mac has one (Launch Services answers Code there). The open-reveal step
# gives the guest one the way a user's choice in Finder's Get Info does, and records it.
MARKDOWN_HANDLER = r"""
import ctypes, json
CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
CS = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreServices.framework/CoreServices')
vp, UTF8, ALL = ctypes.c_void_p, 0x08000100, 0xFFFFFFFF
CF.CFStringCreateWithCString.restype = vp
CF.CFStringCreateWithCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_uint32]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
CS.UTTypeCreatePreferredIdentifierForTag.restype = vp
CS.UTTypeCreatePreferredIdentifierForTag.argtypes = [vp, vp, vp]
CS.LSCopyDefaultRoleHandlerForContentType.restype = vp
CS.LSCopyDefaultRoleHandlerForContentType.argtypes = [vp, ctypes.c_uint32]
CS.LSSetDefaultRoleHandlerForContentType.restype = ctypes.c_int32
CS.LSSetDefaultRoleHandlerForContentType.argtypes = [vp, ctypes.c_uint32, vp]
cf = lambda s: CF.CFStringCreateWithCString(None, s.encode(), UTF8)
def text(ref):
    if not ref:
        return None
    buf = ctypes.create_string_buffer(1024)
    return buf.value.decode() if CF.CFStringGetCString(ref, buf, 1024, UTF8) else None
uti = CS.UTTypeCreatePreferredIdentifierForTag(cf('public.filename-extension'), cf('md'), None)
before = text(CS.LSCopyDefaultRoleHandlerForContentType(uti, ALL))
status = None if before else CS.LSSetDefaultRoleHandlerForContentType(uti, ALL, cf('com.apple.TextEdit'))
print(json.dumps({'type': text(uti), 'before': before, 'set_status': status,
                  'after': text(CS.LSCopyDefaultRoleHandlerForContentType(uti, ALL))}))
"""


# Slice S6: the name the walk gives the copy in the save sheet, so exactly one file in the guest
# can be the copy, and the AppleScript that drives the sheet. The sheet is found on the app's own
# window (bundle com.richos.app); its name field is the one holding the offered name, its Where
# control is its first pop-up button. Prints SHEET<tab>offered<tab>typed<tab>where.
SAVE_AS = 'panel-check copy from the walk.md'
SAVE_SHEET = r'''
tell application "System Events"
  set p to first process whose bundle identifier is "com.richos.app"
  set found to false
  repeat 80 times
    if exists sheet 1 of window 1 of p then
      set found to true
      exit repeat
    end if
    delay 0.25
  end repeat
  if not found then return "NOSHEET"
  set s to sheet 1 of window 1 of p
  delay 1
  set nameField to missing value
  set offered to ""
  set whereName to "?"
  repeat with e in (entire contents of s)
    try
      set r to role of e
      if r is "AXTextField" and nameField is missing value then
        set v to value of e
        if v starts with "panel-check" then
          set nameField to e
          set offered to v
        end if
      else if r is "AXPopUpButton" and whereName is "?" then
        set whereName to value of e
      end if
    end try
  end repeat
  if nameField is missing value then return "NOFIELD"
  set value of nameField to "@NAME@"
  delay 0.5
  return "SHEET" & tab & offered & tab & (value of nameField) & tab & whereName
end tell
'''
SAVE_PRESS = r'''
tell application "System Events"
  set p to first process whose bundle identifier is "com.richos.app"
  set s to sheet 1 of window 1 of p
  repeat with e in (entire contents of s)
    try
      if role of e is "AXButton" and (title of e is "Save") then
        click e
        return "pressed"
      end if
    end try
  end repeat
  return "NOSAVE"
end tell
'''


def project(rows):
    """The list the app will serve, by the PRD's §4.3 rule (cargo run --example is not on the
    VM): one entry per file key (canonical, else path); a row whose path is a land row's
    landedFrom is folded into the landed entry. {file key: its rows}."""
    retired = {r['landedFrom']: r.get('canonical') or r['path'] for r in rows if r.get('source') == 'land' and r.get('landedFrom')}
    entries = {}
    for r in rows:
        key = r.get('canonical') or r['path']
        if r.get('source') != 'land':
            key = retired.get(r['path']) or retired.get(r.get('canonical')) or key
        entries.setdefault(key, []).append(r)
    return entries


class OutputWalk(command_walk.CommandWalk):
    # --- what the guest holds ------------------------------------------------------------------
    def lines(self, path, timeout=60):
        text = guest(self.vm, 'cat ' + shlex.quote(path) + ' 2>/dev/null || true', timeout)
        out = []
        for line in text.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def record(self):
        return self.lines(self.data + '/output/' + self.facts['thread'] + '.jsonl')

    def ledger(self):
        return self.lines(self.data + '/conversation-ledger.jsonl')

    def callbacks(self, session):
        return [row.get('callback', {}) for row in
                self.lines(self.data + '/engine-state/evidence/' + session + '/callbacks.jsonl', 120)]

    def save_record(self, name):
        rows = self.record()
        (self.out / name).write_text(''.join(json.dumps(r, sort_keys=True) + '\n' for r in rows))
        return rows

    # --- one typed message, and the turn it became --------------------------------------------
    def send(self, text):
        known = {r.get('turn_id') for r in self.ledger() if r.get('event') == 'PromptReceived'}
        sent = self.clock()
        self.type_into(text, '--role', 'AXTextArea', '--title', 'Message to Rich')
        self.press('Send')
        end = time.monotonic() + 60
        while time.monotonic() < end:
            new = [r for r in self.ledger() if r.get('event') == 'PromptReceived'
                   and r.get('turn_id') not in known and r.get('thread_id') == self.facts['thread']
                   and r.get('source') != 'internal']
            if new:
                return new[-1]['turn_id'], sent
            time.sleep(1)
        raise StepFailed('the message never became a turn on the conversation')

    def turn_end(self, turn, seconds=420):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            rows = self.ledger()
            done = [r for r in rows if r.get('turn_id') == turn and r.get('event') in ('TurnCompleted', 'TurnInterrupted')]
            if done:
                started = [r for r in rows if r.get('turn_id') == turn and r.get('event') == 'TurnStarted']
                return done[-1], [s.get('session_id') for s in started if s.get('session_id')]
            time.sleep(2)
        raise StepFailed(f'turn {turn} did not end within {seconds} s')

    def words_since(self, sent_ms):
        """Everything Rich said on this thread since the send: his streamed words, and every notice
        on an assignment of this thread."""
        words = [r.get('text', '') for r in self.ledger() if r.get('event') == 'AssistantDelta' and r.get('at', 0) >= sent_ms]
        for a in self.records():
            if a.get('thread_id') == self.facts['thread']:
                words += [n.get('text', '') if isinstance(n, dict) else str(n) for n in a.get('notices', [])]
                words.append(a.get('detail', ''))
        return ''.join(words)

    def turn_story(self, turn):
        """What became of one turn, from the ledger and the question store: how it ended, the
        start of what Rich said, and any question he asked instead of acting."""
        rows = [r for r in self.ledger() if r.get('turn_id') == turn]
        ended = [r for r in rows if r.get('event') in ('TurnCompleted', 'TurnInterrupted')]
        said = ''.join(r.get('text', '') for r in rows if r.get('event') == 'AssistantDelta')
        store = self.lines(self.data + '/engine-state/questions/store.json')
        asked = [q.get('text') for s in store for q in s.get('questions', []) if q.get('turn_id') == turn]
        return {'ended': ended[-1].get('event') if ended else None,
                'stop_reason': ended[-1].get('stop_reason') if ended else None,
                'rich_said': said[:600], 'questions_asked': asked}

    def approve_pending(self, sent_ms):
        """command-walk.py's rule: while the newest job of this send is open, press its Approve
        once when the work panel offers one, at most APPROVALS times in a run. A command that
        waits for his approval is asked while the job is `running`, not only when `blocked`."""
        ours = self.assignments_since(sent_ms)
        newest = max(ours, key=lambda a: a.get('registered_at_ms', 0)) if ours else None
        pressed = self.facts.get('approvals_pressed', 0)
        if newest and newest.get('state') in OPEN and pressed < APPROVALS \
                and self.approve_if_asked(newest.get('title', '')):
            self.facts['approvals_pressed'] = pressed + 1
            self.save()

    def assignments_since(self, sent_ms):
        return [a for a in self.records()
                if a.get('thread_id') == self.facts['thread'] and a.get('registered_at_ms', 0) >= sent_ms - 1000]

    # --- steps ---------------------------------------------------------------------------------
    def tools(self):
        guest(self.vm, 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install pandoc typst >/tmp/output-walk-brew.log 2>&1', 1200)
        versions = guest(self.vm, 'eval "$(/opt/homebrew/bin/brew shellenv)" && pandoc --version | head -1 && typst --version', 60)
        self.facts['tools'] = versions.strip().splitlines()
        self.save()
        return {'tools': self.facts['tools']}

    def pdf(self):
        turn, sent = self.send(PDF_TASK)
        pdf = self.company + '/launch-brief.pdf'
        end = time.monotonic() + self.a.within
        rows = []
        while time.monotonic() < end:
            rows = [r for r in self.record() if r.get('path', '').endswith('/launch-brief.pdf')]
            if rows:
                break
            self.approve_pending(sent)
            time.sleep(5)
        self.save_record('record-after-pdf.jsonl')
        on_disk = guest(self.vm, 'ls -l ' + shlex.quote(pdf) + ' 2>/dev/null || echo absent').strip()
        said = self.words_since(sent)
        evidence = {'turn': turn, 'turn_story': self.turn_story(turn), 'pdf_rows': rows, 'pdf_on_disk': on_disk,
                    'rich_named_the_absolute_path': pdf in said,
                    'assignments': [{k: a.get(k) for k in ('id', 'kind', 'state', 'work_session')}
                                    for a in self.assignments_since(sent)]}
        (self.out / 'pdf-observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        if not rows:
            raise StepFailed('no row for the PDF reached the record within %d s (on disk: %s)' % (self.a.within, on_disk))
        if not any(r.get('source') == 'command' for r in rows):
            raise StepFailed('the PDF is listed, but not by the command witness: ' + json.dumps(rows))
        return evidence

    def work_story(self, sent, sessions):
        """Why a job ended as it did, kept for every run: each assignment's state, detail and last
        notices, and the back-end sessions' tool calls (lead's and workers') with how each ended.
        A PreToolUse with no PostToolUse is a call a hook refused or that never returned."""
        jobs = [{k: a.get(k) for k in ('id', 'state', 'detail')} | {'notices': (a.get('notices') or [])[-6:]}
                for a in self.assignments_since(sent)]
        calls = []
        for session in sessions:
            for c in self.callbacks(session):
                event, tool = c.get('hook_event_name'), c.get('tool_name')
                if event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure') and tool:
                    ti = c.get('tool_input') or {}
                    out = c.get('tool_response', c.get('error'))
                    calls.append({'event': event, 'tool': tool, 'id': c.get('tool_use_id'), 'agent': c.get('agent_id'),
                                  'input': str(ti.get('command') or ti.get('file_path') or ti.get('name') or ti)[:300],
                                  'result': None if event == 'PreToolUse' else str(out)[:600]})
                elif event in ('SubagentStop', 'Stop'):
                    calls.append({'event': event, 'agent': c.get('agent_id'),
                                  'last': str(c.get('last_assistant_message', ''))[:600]})
        return {'jobs': jobs, 'calls': calls}

    def exists_in_guest(self, path):
        return guest(self.vm, 'test -f ' + shlex.quote(path) + ' && echo yes || echo no', 60).strip() == 'yes'

    def backend_worker(self):
        """S2's worker row, then S2b's land (PRD §12.2b): after the job settles, both files are in
        the Acme folder, the record holds a land row for each at the Acme path from the worker's
        worktree, notes.zip's worktree row is the command witness's with the worker's agent id
        (the carve-out, on the real hook), and the list the app will serve names each file once,
        at the Acme path, with nothing no longer where it was written."""
        turn, sent = self.send(WORKER_TASK)
        names = ('notes.md', MADE)
        end = time.monotonic() + self.a.within
        workers, lands = [], []
        while time.monotonic() < end:
            rows = self.record()
            workers = [r for r in rows if r.get('actor') == 'worker']
            lands = [r for r in rows if r.get('source') == 'land']
            ours = self.assignments_since(sent)
            settled = bool(ours) and all(a.get('state') not in OPEN for a in ours)
            if settled or {Path(r.get('path', '')).name for r in lands} >= set(names):
                break
            self.approve_pending(sent)
            time.sleep(5)
        time.sleep(10)  # the work host projects after the back-end turn that landed; one more pass
        rows = self.save_record('record-after-backend-worker.jsonl')
        workers = [r for r in rows if r.get('actor') == 'worker']
        lands = [r for r in rows if r.get('source') == 'land']
        listed = project(rows)
        on_disk = {n: self.exists_in_guest(self.company + '/' + n) for n in names}
        # "Opens": there is no open-file command before slice S3, so the landed copy is read back
        # at the listed path: notes.md's line, and notes.zip's zip header.
        reads = {n: guest(self.vm, 'head -c 32 ' + shlex.quote(self.company + '/' + n) + ' 2>&1 | head -1', 60).strip()
                 for n in names}
        missing = sorted(k for k in listed if not self.exists_in_guest(k))
        sessions = sorted({a.get('work_session') for a in self.assignments_since(sent) if a.get('work_session')})
        mislabeled = [r for r in rows if r.get('actor') == 'rich' and any(r.get('path') == w.get('path') for w in workers)]
        evidence = {'turn': turn, 'turn_story': self.turn_story(turn), 'work_sessions': sessions,
                    'worker_rows': workers, 'land_rows': lands, 'mislabeled_as_rich': mislabeled,
                    'in_acme_folder': on_disk, 'read_back': reads, 'listed': {k: len(v) for k, v in listed.items()},
                    'no_longer_where_written': missing,
                    'assignments': [{k: a.get(k) for k in ('id', 'kind', 'state', 'work_session')}
                                    for a in self.assignments_since(sent)]}
        (self.out / 'backend-worker-observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        (self.out / 'backend-worker-story.json').write_text(json.dumps(self.work_story(sent, sessions), indent=2) + '\n')
        if not workers:
            raise StepFailed('no worker row reached the record within %d s' % self.a.within)
        if not all(w.get('workerName') for w in workers):
            raise StepFailed('a worker row has no worker name: ' + json.dumps(workers))
        if mislabeled:
            raise StepFailed("a worker's file is also listed as Rich's: " + json.dumps(mislabeled))
        if not all(on_disk.values()):
            raise StepFailed('the Acme folder does not hold both files: ' + json.dumps(on_disk))
        if not (reads['notes.md'].startswith('Notes for the walk test') and reads[MADE].startswith('PK')):
            raise StepFailed('a landed copy does not read back as written: ' + json.dumps(reads))
        for name in names:
            acme = self.company + '/' + name
            land = [r for r in lands if r.get('path') == acme]
            if not (land and WORKTREES in land[0].get('landedFrom', '') and land[0].get('workerName')):
                raise StepFailed('no land row for %s at the Acme path from the worker worktree: %s' % (name, json.dumps(lands)))
            at_acme = [k for k in listed if Path(k).name == name and WORKTREES not in k]
            at_worktree = [k for k in listed if Path(k).name == name and WORKTREES in k]
            if len(at_acme) != 1 or at_worktree:
                raise StepFailed('%s is not listed once at the Acme path: %s' % (name, json.dumps(sorted(listed))))
        made = [r for r in rows if r.get('source') == 'command' and WORKTREES in r.get('path', '')
                and r['path'].endswith('/' + MADE) and r.get('agentId')]
        if not made:
            raise StepFailed("no command row for %s in the worker's worktree with its agent id (the carve-out)" % MADE)
        if missing:
            raise StepFailed('listed but no longer where it was written: ' + json.dumps(missing))
        return evidence

    def front_desk_worker(self):
        turn, sent = self.send(FRONT_DESK_TASK)
        ended, sessions = self.turn_end(turn)
        time.sleep(5)  # the spine projects its session at the turn's end; give the write a moment
        calls = [c for s in sessions for c in self.callbacks(s)]
        agent = [c for c in calls if c.get('tool_name') == 'Agent']
        writes = [c for c in calls if c.get('hook_event_name') == 'PostToolUse'
                  and c.get('tool_name') in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit')
                  and str((c.get('tool_input') or {}).get('file_path', '')).endswith('direct.md')]
        rows = self.save_record('record-after-front-desk-worker.jsonl')
        direct_rows = [r for r in rows if r.get('path', '').endswith('/direct.md')]
        by_worker = [w for w in writes if w.get('agent_id')]
        misattributed = [r for r in direct_rows if r.get('actor') == 'rich' and by_worker]
        evidence = {
            'turn': turn, 'turn_end': ended.get('event'), 'turn_story': self.turn_story(turn),
            'front_desk_sessions': sessions,
            'agent_callbacks': [{'event': c.get('hook_event_name'), 'tool_use_id': c.get('tool_use_id'),
                                 'agent_id': c.get('agent_id'), 'name': (c.get('tool_input') or {}).get('name'),
                                 'response': c.get('tool_response') if c.get('hook_event_name') != 'PreToolUse' else None}
                                for c in agent],
            'direct_md_writes': [{'agent_id': w.get('agent_id'), 'path': (w.get('tool_input') or {}).get('file_path')}
                                 for w in writes],
            'direct_md_on_disk': guest(self.vm, 'ls -l ' + shlex.quote(self.company + '/direct.md') + ' 2>/dev/null || echo absent').strip(),
            'direct_md_rows': direct_rows,
            'assignments_registered': [{k: a.get(k) for k in ('id', 'kind', 'state')} for a in self.assignments_since(sent)],
        }
        (self.out / 'front-desk-worker-observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        if misattributed:
            raise StepFailed("a front-desk worker's write is listed as Rich's: " + json.dumps(misattributed))
        return evidence

    # --- slice S3: output_open and output_reveal, through the probe -----------------------------
    def probe(self, *words):
        """One probe verb in the guest; its JSON line."""
        line = guest(self.vm, ' '.join(shlex.quote(w) for w in ('./output_files_probe',) + words) + ' || true', 60)
        try:
            return json.loads(line.splitlines()[-1])
        except (ValueError, IndexError):
            raise StepFailed('the probe printed no answer: ' + line)

    def windows(self):
        """Every window of every foreground process in the guest, as (process, window) pairs."""
        script = ('tell application "System Events"\n'
                  '  set out to ""\n'
                  '  repeat with p in (every process whose background only is false)\n'
                  '    repeat with w in windows of p\n'
                  '      set out to out & (name of p) & tab & (name of w) & linefeed\n'
                  '    end repeat\n'
                  '  end repeat\n'
                  '  return out\n'
                  'end tell')
        text = command([HERE / 'ax.sh', self.vm, script], 60)
        return [tuple(l.split('\t', 1)) for l in text.splitlines() if '\t' in l]

    def wait_for_window(self, wanted, seconds=20):
        """Poll the guest's windows until one matches, at most `seconds`; the last listing."""
        end = time.monotonic() + seconds
        while True:
            listing = self.windows()
            if any(wanted(p, w) for p, w in listing) or time.monotonic() > end:
                return listing
            time.sleep(2)

    # --- slice S4: the panel itself, on the real app ---------------------------------------------
    def panel(self):
        """S4's real-app check (§12.4): a thread with one written file; the Output button opens
        the panel on it; the list is photographed in both themes. The file is made by a shell
        command, so it reaches the record through witness (c) whichever lease runs it."""
        turn, sent = self.send(PANEL_TASK)
        end = time.monotonic() + self.a.within
        rows = []
        while time.monotonic() < end:
            rows = [r for r in self.record() if r.get('path', '').endswith('/panel-check.md')]
            if rows:
                break
            self.approve_pending(sent)
            time.sleep(5)
        self.save_record('record-panel.jsonl')
        evidence = {'turn': turn, 'turn_story': self.turn_story(turn), 'rows': rows}
        observed = self.out / 'panel-observed.json'

        def note(**facts):
            evidence.update(facts)
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        note()
        if not rows:
            raise StepFailed('no row for panel-check.md reached the record within %d s' % self.a.within)
        # The count reaches the buttons from list_output (or rich://output); their name says it.
        try:
            # aria-pressed makes each Output button a toggle: AXCheckBox/AXToggle in the guest's tree.
            self.wait_for('1 file from this thread', role='AXCheckBox', seconds=60)
        except StepFailed:
            # What the window shows instead, kept as evidence: the tree as text, and the picture.
            (self.out / 'panel-ax-tree.txt').write_text(command([HERE / 'ax.sh', self.vm, 'tree'], 120))
            self.shot('panel-no-count.png')
            raise
        self.press('1 file from this thread', role='AXCheckBox')
        self.wait_for('Close the output panel', seconds=20)
        self.wait_for('panel-check.md', seconds=20)
        time.sleep(1.5)  # the panel's 0.38 s slide and the view's fade, with margin
        first_dark = 'Dark' in guest(self.vm, 'defaults read -g AppleInterfaceStyle 2>/dev/null || true')
        first = 'dark' if first_dark else 'light'
        self.shot('panel-' + first + '.png')
        second = 'light' if first_dark else 'dark'
        command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to tell appearance preferences '
                 'to set dark mode to ' + ('false' if first_dark else 'true')], 60)
        try:
            time.sleep(3)  # theme-boot follows the OS appearance live; give the repaint time
            self.shot('panel-' + second + '.png')
            still_open = self.present('Close the output panel')
        finally:
            command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to tell appearance preferences '
                     'to set dark mode to ' + ('true' if first_dark else 'false')], 60)
        note(first_theme=first, shots=['panel-' + first + '.png', 'panel-' + second + '.png'],
             open_after_theme_change=still_open)
        if not still_open:
            raise StepFailed('the panel was not open after the theme change')
        return evidence

    # --- slice S6: Save a copy…, on the real app -------------------------------------------------
    def press_any(self, title, roles, contains=True):
        """Press the first control named `title` in any of `roles`, in that order: WebKit names
        an `aria-haspopup` button and a `role=menuitem` its own way, and the walk records which."""
        for role in roles:
            if self.present(title, role):
                self.press(title, role=role, contains=contains)
                return role
        (self.out / ('ax-tree-' + title.split()[0].lower() + '.txt')).write_text(command([HERE / 'ax.sh', self.vm, 'tree'], 120))
        raise StepFailed('no control named %r in any of %s' % (title, roles))

    def save_copy(self):
        """Slice S6's real-app check (§12.6): *Save a copy…* writes the copy where the sheet
        pointed. Run after the panel step, on its one file: the row's More actions, Save a copy…,
        the system save sheet (a sheet on the app's window, `tauri-plugin-dialog` run from Rust)
        given a name of the walk's own, its folder read from its Where control, Save pressed.
        PASS when the notice says what was saved, exactly one file of that name exists in the
        guest's home, it is in the folder the sheet named, and its bytes are the recorded file's."""
        os.environ['TESTVM_AX_TIMEOUT'] = '90'  # a save panel's whole tree is read once below
        rows = self.record()
        listed = [k for k in project(rows) if Path(k).name == 'panel-check.md' and self.exists_in_guest(k)]
        evidence = {'listed_sources': listed}
        observed = self.out / 'save-copy-observed.json'

        def note(**facts):
            evidence.update(facts)
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        note()
        if not listed:
            raise StepFailed('no recorded panel-check.md exists in the guest: run after the panel step')
        source = listed[0]
        if not self.present('Close the output panel'):
            self.press('1 file from this thread', role='AXCheckBox')
            self.wait_for('Close the output panel', seconds=20)
        more = self.press_any('More actions for panel-check.md', ['AXPopUpButton', 'AXMenuButton', 'AXButton'])
        time.sleep(1)
        item = self.press_any('Save a copy', ['AXMenuItem', 'AXButton'])
        note(more_role=more, item_role=item)
        sheet = command([HERE / 'ax.sh', self.vm, SAVE_SHEET.replace('@NAME@', SAVE_AS)], 120).strip()
        note(sheet=sheet)
        self.shot('save-copy-1-sheet.png')
        parts = sheet.split('\t')
        if parts[0] != 'SHEET':
            (self.out / 'save-copy-ax-tree.txt').write_text(command([HERE / 'ax.sh', self.vm, 'tree'], 120))
            raise StepFailed('the save sheet was not driven: ' + sheet)
        offered, typed, where = parts[1], parts[2], parts[3]
        note(offered_name=offered, typed_name=typed, where=where)
        clicked = command([HERE / 'ax.sh', self.vm, SAVE_PRESS], 60).strip()
        note(save_pressed=clicked)
        said = None
        end = time.monotonic() + 20
        while time.monotonic() < end and said is None:
            try:
                hits = self.ax('find', '--value', 'Saved a copy of panel-check.md', '--role', 'AXStaticText', '--contains', '--first')
                said = hits[0].get('value') if hits else None
            except StepFailed:
                time.sleep(1)
        self.shot('save-copy-2-saved.png')
        found = [l for l in guest(self.vm, 'find /Users -path "*/Library" -prune -o -type f -name ' + shlex.quote(SAVE_AS)
                                  + ' -print 2>/dev/null || true', 120).splitlines() if l.strip()]
        same = [guest(self.vm, 'cmp -s ' + shlex.quote(source) + ' ' + shlex.quote(f) + ' && echo same || echo differ', 60).strip()
                for f in found]
        note(notice=said, copies_found=found, bytes_match=same, source=source)
        if offered != 'panel-check.md':
            raise StepFailed('the sheet was not offered the file\'s own name: ' + offered)
        if typed != SAVE_AS:
            raise StepFailed('the sheet did not take the walk\'s name: ' + typed)
        if len(found) != 1:
            raise StepFailed('expected exactly one copy named %r, found %s' % (SAVE_AS, found))
        if Path(found[0]).parent.name != where:
            raise StepFailed('the copy is in %s, not in the folder the sheet pointed at (%s)' % (Path(found[0]).parent, where))
        if same != ['same']:
            raise StepFailed('the copy\'s bytes are not the recorded file\'s')
        if not (said and SAVE_AS in said):
            raise StepFailed('the notice did not say what was saved: %r' % said)
        return evidence

    def open_reveal(self):
        if not self.a.probe or not self.a.probe.is_file():
            raise StepFailed('--probe must name the built examples/output_files_probe binary')
        command([HERE / 'guest.sh', self.vm, '--push', self.a.probe, 'output_files_probe'], 120)
        folder = self.home + '/Acme'
        brief = folder + '/walk-brief.md'
        data = self.payload + '/probe-data'
        thread = 'thr_walk_open_reveal'
        guest(self.vm, 'chmod +x output_files_probe && mkdir -p ' + shlex.quote(folder) + ' ' + shlex.quote(data)
              + " && printf '# Walk brief\\n\\nOpened by its output id.\\n' > " + shlex.quote(brief))
        evidence = {}
        observed = self.out / 'open-reveal-observed.json'

        def note(**facts):
            evidence.update(facts)
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        handler = guest(self.vm, 'python3 -c ' + shlex.quote(MARKDOWN_HANDLER), 60)
        note(markdown_handler=json.loads(handler.splitlines()[-1]))
        recorded = self.probe('record', data, thread, brief)
        note(recorded=recorded)
        if 'ok' not in recorded:
            raise StepFailed('the file could not be recorded: ' + json.dumps(recorded))
        output_id = recorded['ok']['id']
        detail = self.probe('file', data, thread, output_id)
        note(output_id=output_id, detail=detail,
             default_app=((detail.get('ok') or {}).get('defaultApp') or {}).get('name'))
        opened = self.probe('open', data, thread, output_id)
        note(opened=opened)
        after_open = self.wait_for_window(lambda p, w: p != 'Finder' and 'walk-brief.md' in w)
        self.shot('open-reveal-1-opened.png')
        note(windows_after_open=after_open)
        revealed = self.probe('reveal', data, thread, output_id)
        note(revealed=revealed)
        after_reveal = self.wait_for_window(lambda p, w: p == 'Finder' and w == 'Acme')
        self.shot('open-reveal-2-revealed.png')
        note(windows_after_reveal=after_reveal)
        # Finder's selection is not read through Apple Events: the guest has no Automation grant,
        # and the consent prompt that asking would raise holds the call open. The second
        # screenshot is where the selection is seen (§12.3: "observed through the walk
        # harness's screenshot").
        if 'ok' not in opened:
            raise StepFailed('output_open refused: ' + json.dumps(opened))
        if 'ok' not in revealed:
            raise StepFailed('output_reveal refused: ' + json.dumps(revealed))
        if not any(p != 'Finder' and 'walk-brief.md' in w for p, w in after_open):
            raise StepFailed('no app shows a window for walk-brief.md after output_open: ' + json.dumps(after_open))
        if not any(p == 'Finder' and w == 'Acme' for p, w in after_reveal):
            raise StepFailed('Finder shows no window for the folder after output_reveal: ' + json.dumps(after_reveal))
        return evidence

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--within', type=float, default=900, help='seconds for each file to reach the record')
    p.add_argument('--steps', default=','.join(s for s in STEPS if s not in ('open-reveal', 'panel', 'save-copy')),
                   help='default: every step but open-reveal (alone, with --no-app), panel '
                        '(S4: --steps identity,first-run,connect,panel) and save-copy '
                        '(S6: --steps identity,first-run,connect,panel,save-copy)')
    p.add_argument('--probe', type=Path, help='open-reveal: the built examples/output_files_probe')
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = OutputWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'steps': []}
    ok = True
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except (StepFailed, RuntimeError, subprocess.TimeoutExpired) as exc:
            row['outcome'] = 'FAIL'
            row['detail'] = str(exc)
            ok = False
        row['seconds'] = round(time.monotonic() - began, 1)
        report['steps'].append(row)
        (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{step}: {row['outcome']}" + (f" — {row.get('detail')}" if row['outcome'] != 'PASS' else ''), flush=True)
        # The three witness checks are independent: one failing does not skip the next.
        if not ok and step in ('identity', 'first-run', 'connect', 'tools'):
            break
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
