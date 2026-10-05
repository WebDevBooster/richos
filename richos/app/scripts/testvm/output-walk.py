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

  previews           slice S5's real-app check (§12.5), after identity, first-run and connect:
                       --steps identity,first-run,connect,previews
                     typed: a shell command prints a text file to preview-brief.pdf (cupsfilter) and
                     draws its first page as preview-page.png (sips). When both rows are in the
                     record, the Output button opens the panel; each file is opened from the list
                     and its view photographed in both themes (the guest's appearance flipped and
                     put back). PASS when the picture is an image named for the file and the PDF
                     frame is found by its title; what each view shows is read off the photographs.
  save-copy          slice S6's real-app check (§12.6), after the panel step:
                       --steps identity,first-run,connect,panel,save-copy
                     on the panel's one file: its row's More actions, Save a copy…, and the system
                     save sheet that opens on the app's window. The sheet must offer the file's own
                     name; the walk gives it SAVE_AS instead, reads its Where folder, presses Save.
                     PASS when exactly one file named SAVE_AS exists in the guest, in the folder the
                     sheet named, with the recorded file's bytes. Both moments are photographed
                     (save-copy-1-sheet.png; save-copy-2-saved.png 1.5 s after Save, while the
                     notice is up), and whether an accessibility search read the notice is recorded.
  attach             slice S7's real-app check (§12.7), after identity, first-run and connect:
                       --steps identity,first-run,connect,attach
                     typed: a shell command writes attach-check.md, with a code word in it, at its
                     absolute path in the Acme folder. When its row is in the record and the file is
                     on disk, the Output button, the row's own "More actions for …" (S6's menu) and
                     its last item "Add to chat" are pressed by name and the chip's "Remove
                     attach-check.md" is found;
                     then Rich is asked for the code word in the attached file. PASS when that
                     turn's prompt lists the file under "Attached on this Mac (1 file" and the
                     conversation's attachments folder holds a byte-identical copy. Whether Rich
                     read the code word back is recorded, not judged.
  pull               slice S9's real-app check (§12.9), after panel, in the same run; run last when
                     previews, save-copy and attach run too, so they find the panel at its split:
                       --steps identity,first-run,connect,tools,panel,previews,save-copy,attach,pull
                     The divider is dragged with the real mouse (pointer-drag.sh): 50 px past the
                     stop and let go — it holds at the stop (photographed); pulled 180 px past it —
                     it opens completely, ‹ <thread> appears (photographed); the pill brings the
                     conversation back at the stop; the sidebar is hidden and the divider pulled
                     past the new stop — the whole window (photographed); the panel is closed —
                     the whole conversation is back (photographed); the sidebar comes back and the
                     panel reopens at a split width. PASS when every position is where the
                     geometry says (the stop is the rail's right edge + 360 px, read off the
                     accessibility tree) and every control is found by its name.

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
         'previews', 'save-copy', 'attach', 'pull']
# Slice S9 (PRD §9.1): the conversation at its narrowest. Restated, not imported, so the walk
# derives the stop independently of the code under test.
STAGE_MIN = 360
# S7's recorded file. Written at its ABSOLUTE path in the Acme folder, so it is in the Acme folder
# whichever lease or worker runs the command (S4's walk saw a worker run panel-check.md in its own
# worktree), and its code word is what Rich is asked to read back from the attached copy.
ATTACH_NAME = 'attach-check.md'
ATTACH_WORD = 'heron-4127'
ATTACH_TASK = ('Please run this harmless test command for me yourself with your shell tool, '
               "and tell me when it has finished: printf '# Attach check\\n\\nThe code word is %s.\\n' > %s")
ATTACH_ASK = 'What is the code word in the attached file? Reply with the code word only.'
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
# S5's real PDF and real PNG (§12.5), made with what every Mac has, so nothing needs installing:
# cupsfilter prints the text to a PDF, and sips draws that PDF's first page as a PNG.
PREVIEW_TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme folder, '
                "and tell me when it has finished: printf 'Preview brief\\n\\nA real PDF for the walk test.\\n' > preview-brief.txt "
                '&& /usr/sbin/cupsfilter preview-brief.txt > preview-brief.pdf 2>/dev/null '
                '&& /usr/bin/sips -s format png preview-brief.pdf --out preview-page.png')
# The PNG first: with WebKit's PDF view on screen a find through the window's accessibility tree
# outlives ax.sh's 20 s guest deadline (the third walk, 2026-10-05, pressing "All output"), so
# the PDF is the last view the step opens and nothing is looked up after it.
PREVIEW_FILES = (('preview-page.png', 'png'), ('preview-brief.pdf', 'pdf'))
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
# window (bundle com.richos.app). Its controls are the sheet's own children, as the walk's AX tree
# showed them (attempt 4): text field 1 is Save As, pop up button 1 is Where, then the Save button. Prints SHEET<tab>offered<tab>typed<tab>where.
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
  set nameField to text field 1 of s
  set offered to value of nameField
  set whereName to value of pop up button 1 of s
  set value of nameField to "@NAME@"
  delay 0.5
  return "SHEET" & tab & offered & tab & (value of nameField) & tab & whereName
end tell
'''
SAVE_PRESS = r'''
tell application "System Events"
  set p to first process whose bundle identifier is "com.richos.app"
  click button "Save" of sheet 1 of window 1 of p
  return "pressed"
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

    # --- slice S9: the wide pull, on the real app -------------------------------------------------
    def node(self, title, role=None):
        """The first accessibility node named `title`: its frame (x, y, w, h) and value."""
        args = ['--title', title, '--contains', '--first']
        if role:
            args += ['--role', role]
        hits = [n for n in self.ax('find', *args) if 'x' in n and not n.get('meta')]
        if not hits:
            raise StepFailed('nothing on screen is named "%s"' % title)
        return hits[0]

    def press_named(self, title):
        """Press a control by its name whatever role the guest's tree gives it: an AXPress when it
        is a button, else a real click at its center (a toggle with aria-expanded or aria-pressed
        is not always an AXButton in WebKit's tree)."""
        try:
            return self.press(title)
        except StepFailed:
            n = self.node(title)
            return command([HERE / 'ax.sh', self.vm, 'click', '--at',
                            '%.0f,%.0f' % (n['x'] + n['w'] / 2, n['y'] + n['h'] / 2)], 60)

    def drag(self, *points):
        """A real mouse drag through `points` (pointer-drag.sh), in guest screen coordinates."""
        out = command([HERE / 'pointer-drag.sh', self.vm, *['%.0f,%.0f' % p for p in points]], 90)
        return json.loads(out.strip().splitlines()[-1])

    def pull(self):
        """S9's real-app check (§12.9): the drag on the VM, a picture at the stop and one with the
        panel open completely; then the CEO's other two sentences — the sidebar toggled away with
        the panel pulled to the whole window, and closing brings the whole conversation back."""
        evidence = {}
        observed = self.out / 'pull-observed.json'

        def note(**facts):
            evidence.update(facts)
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        def near(a, b, tol, what):
            if abs(a - b) > tol:
                note(failed=what)
                raise StepFailed('%s: %.1f is not within %d px of %.1f' % (what, a, tol, b))

        if not self.present('Close the output panel'):
            self.press('1 file from this thread', role='AXCheckBox')
            self.wait_for('Close the output panel', seconds=20)
        time.sleep(1)
        rail = self.node('Entities and threads')
        divider = self.node('Output panel width')
        rail_right = rail['x'] + rail['w']
        stop = rail_right + STAGE_MIN
        y = divider['y'] + divider['h'] / 2
        grab = divider['x'] + divider['w'] / 2
        note(rail=rail, divider_before=divider, stop_x=stop)
        if divider['x'] - stop < 40:
            raise StepFailed('the window is too narrow to pull: the divider is %.0f px from the stop' % (divider['x'] - stop))

        # 1. Pulled 50 px past the stop and let go: the divider held at the stop.
        note(drag_to_stop=self.drag((grab, y), (stop + 60, y), (stop, y), (stop - 50, y)))
        time.sleep(1.2)
        at_stop = self.node('Output panel width')
        note(divider_at_stop=at_stop)
        near(at_stop['x'], stop, 4, 'the divider at the stop after a 50 px overshoot')
        self.shot('pull-stop.png')

        # 2. Pulled 180 px past it: open completely, ‹ <thread> at the head.
        grab = at_stop['x'] + at_stop['w'] / 2
        note(drag_past_stop=self.drag((grab, y), (stop - 60, y), (stop - 180, y)))
        time.sleep(1.5)
        self.wait_for('Show the conversation', seconds=10)
        full = self.node('Output panel width')
        note(divider_full=full, pill=self.node('Show the conversation'))
        near(full['x'], rail_right, 4, 'open completely, the divider at the rail')
        self.shot('pull-full.png')

        # 3. The pill: the conversation one click back, at the stop.
        self.press_named('Show the conversation')
        time.sleep(1.2)
        back = self.node('Output panel width')
        note(divider_after_pill=back, pill_after_by_name=self.present('Show the conversation'))
        near(back['x'], stop, 4, 'the pill returns to the stop')

        # 4. The sidebar away, and the divider pulled past the new stop: the whole window.
        self.press_named('Hide the sidebar')
        time.sleep(1.2)
        left = rail['x']
        new_stop = left + STAGE_MIN
        moved = self.node('Output panel width')
        grab = moved['x'] + moved['w'] / 2
        note(divider_sidebar_away=moved, new_stop_x=new_stop,
             drag_everything=self.drag((grab, y), (new_stop, y), (new_stop - 60, y), (new_stop - 180, y)))
        time.sleep(1.5)
        self.wait_for('Show the conversation', seconds=10)
        everything = self.node('Output panel width')
        note(divider_everything=everything)
        near(everything['x'], left, 4, 'sidebar away and open completely, the divider at the window edge')
        self.shot('pull-everything.png')

        # 5. Closing brings the whole conversation back.
        self.press_named('Close the output panel')
        time.sleep(1.2)
        whole = self.node('Message to Rich', role='AXTextArea')
        note(composer_after_close=whole, panel_after_close=self.present('Close the output panel'))
        if evidence['panel_after_close']:
            raise StepFailed('the panel did not close')
        if whole['x'] > left + 400:
            raise StepFailed('the composer is not back in the whole conversation: ' + json.dumps(whole))
        self.shot('pull-closed.png')

        # 6. The sidebar back and the panel reopened: a split width, never open completely.
        self.press_named('Show the sidebar')
        time.sleep(1.2)
        self.press('1 file from this thread', role='AXCheckBox')
        self.wait_for('Close the output panel', seconds=20)
        time.sleep(1.2)
        reopened = self.node('Output panel width')
        # Judged by the divider, not by the pill: the divider's value is the painted width
        # (aria-valuenow), and open completely is the rail's right edge, not the stop. A name
        # search for the pill answered True on the first run while the divider sat at the stop
        # with value 740 (the split width), so its presence is recorded, never trusted alone.
        note(divider_reopened=reopened, pill_reopened_by_name=self.present('Show the conversation'))
        self.shot('pull-reopened.png')
        near(reopened['x'], stop, 4, 'reopened at the split width, held at the stop')
        if abs(reopened['x'] - rail_right) <= 4:
            raise StepFailed('the panel reopened open completely: ' + json.dumps(reopened))
        return evidence

    def open_panel(self):
        """Open the Output panel unless a step before this one left it open: the Output button is a
        toggle (`aria-pressed`, an AXCheckBox), so pressing it on an open panel CLOSES it. The steps
        were written one slice at a time, each starting from a closed panel; run together (panel,
        previews, save-copy, attach) they inherit each other's open panel, and the button's name
        carries the count ("3 files from this thread"), so it is found by the part that never moves."""
        if self.present('Close the output panel'):
            return 'already open'
        self.wait_for('from this thread', role='AXCheckBox', seconds=60)
        self.press('from this thread', role='AXCheckBox')
        self.wait_for('Close the output panel', seconds=20)
        return 'opened'

    # --- slice S5: a real PDF and a real PNG previewed in the panel -----------------------------
    def flip_theme(self, stem):
        """Photograph the screen in the guest's appearance, flip it, photograph again, put it back.
        The app follows the OS on a fresh install (theme-boot), so this is both themes."""
        first_dark = 'Dark' in guest(self.vm, 'defaults read -g AppleInterfaceStyle 2>/dev/null || true')
        first = 'dark' if first_dark else 'light'
        second = 'light' if first_dark else 'dark'
        self.shot(stem + '-' + first + '.png')
        command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to tell appearance preferences '
                 'to set dark mode to ' + ('false' if first_dark else 'true')], 60)
        try:
            time.sleep(3)  # theme-boot follows the OS appearance live; give the repaint time
            self.shot(stem + '-' + second + '.png')
        finally:
            command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to tell appearance preferences '
                     'to set dark mode to ' + ('true' if first_dark else 'false')], 60)
            time.sleep(2)
        return [stem + '-' + first + '.png', stem + '-' + second + '.png']

    def previews(self):
        """S5's real-app check (§12.5): a real PDF and a real PNG written by Rich preview in the
        panel, photographed in both themes."""
        turn, sent = self.send(PREVIEW_TASK)
        end = time.monotonic() + self.a.within
        rows = {}
        while time.monotonic() < end:
            record = self.record()
            rows = {n: [r for r in record if r.get('path', '').endswith('/' + n)] for n, _ in PREVIEW_FILES}
            if all(rows.values()):
                break
            self.approve_pending(sent)
            time.sleep(5)
        self.save_record('record-previews.jsonl')
        evidence = {'turn': turn, 'turn_story': self.turn_story(turn), 'rows': rows, 'files': {}}
        observed = self.out / 'previews-observed.json'

        def note():
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        note()
        missing = [n for n, found in rows.items() if not found]
        if missing:
            raise StepFailed('no row reached the record within %d s for: %s' % (self.a.within, ', '.join(missing)))
        evidence['on_disk'] = {n: guest(self.vm, 'ls -l ' + shlex.quote(rows[n][-1]['path']) + ' 2>&1 | head -1', 60).strip()
                               for n, _ in PREVIEW_FILES}
        note()
        self.open_panel()
        failures = []
        for name, kind in PREVIEW_FILES:
            self.wait_for(name, seconds=20)
            # The row, or the conversation's link to the same file: either opens its file view.
            self.press(name)
            self.wait_for('All output', seconds=20)
            time.sleep(4)  # the read, the decode and WebKit's PDF view; the viewer says Reading… meanwhile
            # The pictures first: they are the evidence, and nothing after them can lose them.
            shots = self.flip_theme('preview-' + kind)
            # Then the viewer, by name, through targeted finds: a whole-tree read of this window
            # outlived ax.sh's 20 s guest deadline on the second walk (2026-10-05). The picture is
            # an AXImage described by its alt text, the file's name; the PDF frame is named by its
            # title, and the role WebKit gives a frame holding its PDF view is recorded as found.
            seen = {}
            roles = ('AXImage',) if kind == 'png' else ('AXGroup', 'AXWebArea', 'AXScrollArea')
            for role in roles:
                try:
                    seen[role] = self.present(name, role=role)
                except StepFailed as exc:
                    seen[role] = 'unknown: ' + str(exc).splitlines()[0][:160]
                if seen[role] is True:
                    break
            evidence['files'][name] = {'shots': shots, 'viewer_found_as': seen}
            note()
            if not any(v is True for v in seen.values()):
                failures.append(name + ': no ' + '/'.join(roles) + ' named for the file in its view: ' + json.dumps(seen))
            # Back to the list with Escape (§6.8: the file view steps back to the list), a key
            # press that needs no lookup in the window's tree.
            command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to key code 53'], 60)
            time.sleep(1)
        if failures:
            raise StepFailed('; '.join(failures))
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
        PASS when the sheet offered the file's own name, exactly one file of the walk's name exists
        in the guest's home, it is in the folder the sheet named, and its bytes are the recorded
        file's. The notice is photographed and, when a search catches it, read."""
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
        self.open_panel()
        more = self.press_any('More actions for panel-check.md', ['AXPopUpButton', 'AXMenuButton', 'AXButton'])
        time.sleep(1)
        item = self.press_any('Save a copy', ['AXMenuItem', 'AXButton'])
        note(more_role=more, item_role=item)
        raw = command([HERE / 'ax.sh', self.vm, SAVE_SHEET.replace('@NAME@', SAVE_AS)], 120)
        # ax.sh prints its own timing lines as JSON around the script's answer.
        sheet = next((l for l in raw.splitlines() if l.startswith(('SHEET', 'NOSHEET'))), raw.strip())
        note(sheet=sheet)
        self.shot('save-copy-1-sheet.png')
        parts = sheet.split('\t')
        if parts[0] != 'SHEET':
            (self.out / 'save-copy-ax-tree.txt').write_text(command([HERE / 'ax.sh', self.vm, 'tree'], 120))
            raise StepFailed('the save sheet was not driven: ' + sheet)
        offered, typed, where = parts[1], parts[2], parts[3]
        note(offered_name=offered, typed_name=typed, where=where)
        clicked = next((l for l in command([HERE / 'ax.sh', self.vm, SAVE_PRESS], 60).splitlines() if l == 'pressed'), None)
        note(save_pressed=clicked)
        # The notice stays about 5 s for this sentence; under load one accessibility search takes
        # longer than that (attempt 5 searched for 20 s and photographed after it had gone), so the
        # picture is taken first and the search is one try, kept as evidence beside it.
        time.sleep(1.5)
        self.shot('save-copy-2-saved.png')
        said = None
        try:
            hits = self.ax('find', '--value', 'Saved a copy of panel-check.md', '--role', 'AXStaticText', '--contains', '--first')
            said = hits[0].get('value') if hits else None
        except StepFailed as exc:
            said = None
            note(notice_search=str(exc)[-300:])
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
        # The notice's words are proven by tests/output.js against the shell's sentence; here they
        # are recorded when the search catches them, and the picture shows them either way.
        note(notice_read_by_accessibility=bool(said and SAVE_AS in said))
        return evidence

    # --- slice S7: Add to chat, on the real app -------------------------------------------------
    def attach(self):
        """S7's real-app check (§12.7): a recorded file is attached from the Output panel and
        sent; Rich's turn lists it under *Attached on this Mac*. Every press is by the name a
        person sees: the Output button, the row's `⋯` (*More actions for …*, S6's menu), its last
        item *Add to chat*, the chip's *Remove …* (found, not pressed), the composer and Send."""
        target = self.company + '/' + ATTACH_NAME
        turn, sent = self.send(ATTACH_TASK % (ATTACH_WORD, shlex.quote(target)))
        end = time.monotonic() + self.a.within
        rows = []
        while time.monotonic() < end:
            rows = [r for r in self.record() if r.get('path', '').endswith('/' + ATTACH_NAME)]
            if rows and self.exists_in_guest(target):
                break
            self.approve_pending(sent)
            time.sleep(5)
        self.save_record('record-attach.jsonl')
        evidence = {'turn': turn, 'turn_story': self.turn_story(turn), 'rows': rows,
                    'on_disk': self.exists_in_guest(target)}
        observed = self.out / 'attach-observed.json'

        def note(**facts):
            evidence.update(facts)
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        note()
        if not rows or not evidence['on_disk']:
            raise StepFailed('no row for %s with the file on disk within %d s' % (ATTACH_NAME, self.a.within))
        # Each press by name, in order; the one that missed is named in the evidence. On a miss the
        # screenshot is kept, and the original failure is the one reported: a slow tree dump
        # (ax.sh tree hit its own deadline on the first S7 walk) must not replace it.
        try:
            opened = self.open_panel()
        except (StepFailed, RuntimeError, subprocess.TimeoutExpired) as exc:
            note(presses_done=[], missed={'verb': 'open', 'title': 'the Output panel', 'error': str(exc)[:600]})
            raise StepFailed('the Output panel did not open: %s' % str(exc)[:300])
        note(panel=opened)
        presses = [('wait', ATTACH_NAME, 'AXButton', 20),
                   # The ROW's `⋯` (S6's, beside the row in the list), not the file view's: the row is
                   # not pressed. aria-haspopup="menu" makes WebKit expose the `⋯` as AXPopUpButton,
                   # not AXButton (the second S7 walk waited 20 s for an AXButton that was on screen).
                   ('wait', 'More actions for ' + ATTACH_NAME, 'AXPopUpButton', 20),
                   ('press', 'More actions for ' + ATTACH_NAME, 'AXPopUpButton', 0), ('wait', 'Add to chat', 'AXMenuItem', 20),
                   ('press', 'Add to chat', 'AXMenuItem', 0), ('wait', 'Remove ' + ATTACH_NAME, 'AXButton', 30)]
        done = []
        for verb, title, role, seconds in presses:
            try:
                if verb == 'wait':
                    self.wait_for(title, role=role, seconds=seconds)
                else:
                    self.press(title, role=role)
            except (StepFailed, RuntimeError, subprocess.TimeoutExpired) as exc:
                note(presses_done=done, missed={'verb': verb, 'title': title, 'role': role, 'error': str(exc)[:600]})
                try:
                    self.shot('attach-miss.png')
                except (StepFailed, RuntimeError, subprocess.TimeoutExpired):
                    pass
                raise StepFailed('%s %s "%s" failed: %s' % (verb, role, title, str(exc)[:300]))
            done.append(verb + ' ' + title)
        note(presses_done=done)
        time.sleep(1)
        self.shot('attach-chip.png')
        asked, asked_at = self.send(ATTACH_ASK)
        ended, _ = self.turn_end(asked)
        prompt = [r for r in self.ledger() if r.get('turn_id') == asked and r.get('event') == 'PromptReceived']
        text = json.dumps(prompt)
        stored = guest(self.vm, 'find ' + shlex.quote(self.data + '/attachments') + ' -name ' + shlex.quote(ATTACH_NAME)
                       + ' -type f 2>/dev/null || true', 60).splitlines()  # one path a line: "Application Support"
        same = bool(stored) and guest(self.vm, 'cmp -s ' + shlex.quote(stored[0]) + ' ' + shlex.quote(target)
                                      + ' && echo same || echo differ', 60).strip() == 'same'
        said = ''.join(r.get('text', '') for r in self.ledger() if r.get('turn_id') == asked and r.get('event') == 'AssistantDelta')
        time.sleep(1)
        self.shot('attach-sent.png')
        note(asked_turn=asked, asked_end=ended.get('event'), prompt_rows=prompt, stored_copies=stored,
             stored_copy_matches_the_recorded_file=same, rich_said=said[:600],
             rich_read_the_code_word=ATTACH_WORD in said)
        if 'Attached on this Mac (1 file' not in text or ATTACH_NAME not in text:
            raise StepFailed("Rich's turn does not list %s under Attached on this Mac: %s" % (ATTACH_NAME, text[:800]))
        if not same:
            raise StepFailed('the conversation folder does not hold a copy of the recorded file: ' + json.dumps(stored))
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
    p.add_argument('--steps', default=','.join(s for s in STEPS
                                               if s not in ('open-reveal', 'panel', 'previews', 'save-copy', 'attach', 'pull')),
                   help='default: every step but open-reveal (alone, with --no-app) and the panel steps, '
                        'which run together after identity, first-run and connect: '
                        '--steps identity,first-run,connect,tools,panel,previews,save-copy,attach,pull '
                        '(S4 panel, S5 previews, S6 save-copy, S7 attach, S9 pull)')
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
