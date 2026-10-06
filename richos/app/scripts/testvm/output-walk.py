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
  md-view            after panel, in the same run: --steps identity,first-run,connect,panel,md-view
                     panel-check.md opened from its row, its Markdown view photographed in both
                     themes. PASS when its heading "Panel check" is on screen and the app's frame
                     has not moved: the panel's Close is level with the header's sidebar toggle
                     (within 40 px), as it cannot be if `#app` scrolled (nightly a1a26a615).

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

  THE CANDIDATE WALK'S STEPS (added with the candidate 38 walk, 2026-10-06): what the slice steps
  above never pressed, the way the CEO will use it. All run in the same run as the slice steps:
    --steps identity,first-run,connect,tools,empty,backend-worker,panel,md-view,previews,csv,
            save-copy,attach,buttons,link,actions,missing,overlap,wrote,theme-flash,pull,sidebar
  empty        before any file: both Output buttons say "nothing produced yet"; the panel's empty
               sentence, in both themes.
  csv          typed: a shell command writes walk-table.csv. Its table preview (the first rows)
               in both themes; then panel-check.md's Preview | Source switch, both ways.
  buttons      BOTH Output buttons (top and bottom, found by name, told apart by height) carry the
               same count and each opens the panel; the list's rows, their order and their groups
               are recorded (a worker's landed file, newest first).
  link         a file link in the conversation, pressed with the panel closed, opens that file's
               own view in the panel.
  actions      Open (the row's), Open with (the file view's ▾), Show in Finder (the row's ⋯),
               Copy path (the row's right-click, a real right button: pointer-drag.sh --right),
               the file view's ⋯ and its Copy path.
  missing      walk-table.csv deleted in the guest (the deletion checked), the panel reopened:
               its row says it is gone, and its actions are off with the reason (each item's
               enabled state and AXHelp), in the row's ⋯ and in its own view.
  menus        the row's ⋯ menu and the file view's ⋯ menu, each open in both themes (contrast).
  overlap      after backend-worker: with the panel open, the work summary is opened from its
               chip; FAIL when the Output panel stays open beside it (§6.1, both ways).
  job-question after backend-worker: with the app never relaunched, a job's question card is on
               the conversation and NO "last time RichOS was open" card or "Status unavailable" row
               is (walk 38, D8). When the job did not ask on its own, the walk asks once through
               the app's own job question tool (--questions-mcp) with the job's obligation as its
               turn, the scope a work lease is given, and records which of the two happened.
  wrote        every "Wrote N files" in the conversation pressed in turn: the panel opens on it
               and the app's frame does not move (the header toggle and the composer hold).
  theme-flash  with the panel open, the guest's appearance is flipped while timeline.py captures
               the panel (in the guest) on one clock; the frames are pulled for contrast.py.
  sidebar      the sidebar hidden by its button (the conversation takes the width), ⌘⇧S both ways,
               then a relaunch with it hidden: it comes back hidden; shown again by its button.
  pull         (above) also records the composer at the stop and fails when it has grown taller
               than the one line it is with the panel closed.

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
         'md-view', 'previews', 'save-copy', 'attach', 'pull',
         'empty', 'csv', 'buttons', 'link', 'actions', 'missing', 'menus', 'overlap', 'job-question', 'wrote', 'theme-flash', 'sidebar']
# The candidate walk's steps: never in the default list, which runs the witness checks.
CANDIDATE_STEPS = ('empty', 'csv', 'buttons', 'link', 'actions', 'missing', 'menus', 'overlap', 'job-question', 'wrote',
                   'theme-flash', 'sidebar')
# VERBATIM from timeline.js renderUnknownCard and durationRow: what a turn a quit left running shows.
QUIT_CARD = 'last time RichOS was open'
STATUS_UNAVAILABLE = 'Status unavailable'
# The csv step's file, and a table every word of which is given.
CSV_NAME = 'walk-table.csv'
CSV_TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme folder, '
            "and tell me when it has finished: printf 'region,units\\nNorth,12\\nSouth,7\\n' > " + CSV_NAME)
# VERBATIM from output-panel.js MISSING_SENTENCE (and output_files.rs MISSING): the reason every
# action of a file that is no longer where it was written gives.
MISSING_SENTENCE = ('This file is no longer where it was written. If it was moved, open it from its new place; '
                    'if Rich writes it again, it will be listed here.')
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

    # --- the Markdown file view, and the app's frame held still ------------------------------------
    def heading(self, words):
        """Whether a heading reading `words` is on screen, and how it was found. `present` looks
        for an AXButton by default, which a heading never is (the first md-view walk, 2026-10-05,
        photographed "Panel check" and reported it absent); the Markdown renderer's heading is a
        `role="heading"` node, which WebKit names by its text, and its text is a static text whose
        VALUE carries the words."""
        if self.present(words, role='AXHeading'):
            return True
        try:
            return bool(self.ax('find', '--value', words, '--role', 'AXStaticText', '--contains', '--first'))
        except StepFailed as exc:
            if 'notfound' in str(exc) or 'nothing matched' in str(exc):
                return False
            raise

    def md_view(self):
        """The panel's Markdown file view on the real app, after the panel step: panel-check.md
        opened from its row and photographed in both themes (nightly a1a26a615 refused its picture of
        this view, `output-file-md-dark.png`, because the whole shell had scrolled up). The frame is
        judged from the accessibility tree: the sidebar toggle sits in the sticky conversation
        header and the panel's Close in the panel's own head, both in the window's top band. Had
        `#app` scrolled by N px, the header would have stayed and the panel's head gone up by N, so
        the two must still be level."""
        evidence = {'panel': self.open_panel()}
        observed = self.out / 'md-view-observed.json'

        def note(**facts):
            evidence.update(facts)
            observed.write_text(json.dumps(evidence, indent=2) + '\n')

        self.wait_for('panel-check.md', seconds=20)
        self.press('panel-check.md')
        self.wait_for('All output', seconds=20)
        time.sleep(2)  # the read and the view's fade, with margin
        note(shots=self.flip_theme('md-view'), heading=self.heading('Panel check'))
        toggle = self.node('Hide the sidebar')
        close = self.node('Close the output panel')
        note(sidebar_toggle=toggle, panel_close=close, level_gap=round(abs(close['y'] - toggle['y']), 1))
        # Back to the list (§6.8), so a step after this one finds the panel as the panel step left it.
        command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to key code 53'], 60)
        time.sleep(1)
        if evidence['heading'] is not True:
            raise StepFailed('the Markdown view did not show the file\'s heading "Panel check"')
        if evidence['level_gap'] > 40:
            raise StepFailed("the app's frame moved: the panel's Close is %.0f px from the header's sidebar toggle"
                             % evidence['level_gap'])
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

        # Run after previews, save-copy and attach the panel is already open and the button's name
        # counts every file those steps wrote (5 on the combined walk), not one: open_panel finds
        # it by the part of its name that never moves.
        note(panel=self.open_panel())
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
        # The conversation at its narrowest: its message field must still be one line (judged
        # below against the field with the panel closed).
        note(composer_at_stop=self.node('Message to Rich', role='AXTextArea'))
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
        if evidence['composer_at_stop']['h'] > whole['h'] + 6:
            raise StepFailed('the message field grew at the stop: %.0f px tall, %.0f px with the panel closed'
                             % (evidence['composer_at_stop']['h'], whole['h']))
        self.shot('pull-closed.png')

        # 6. The sidebar back and the panel reopened: a split width, never open completely.
        self.press_named('Show the sidebar')
        time.sleep(1.2)
        note(reopen=self.open_panel())
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

    # --- the candidate walk: what the slice steps never pressed ------------------------------------
    def observed(self, name):
        """An evidence dict and its `note`, written to `<name>-observed.json` at every note, so a
        step that fails half-way keeps what it saw."""
        evidence = {}
        path = self.out / (name + '-observed.json')

        def note(**facts):
            evidence.update(facts)
            path.write_text(json.dumps(evidence, indent=2) + '\n')
        return evidence, note

    def find_all(self, title, role=None, contains=True, by='--title'):
        """Every node matching, [] when nothing does (a find is exhaustive without --first)."""
        args = [by, title] + (['--role', role] if role else []) + (['--contains'] if contains else [])
        try:
            return [n for n in self.ax('find', *args) if 'x' in n and not n.get('meta')]
        except StepFailed as exc:
            if 'notfound' in str(exc) or 'nothing matched' in str(exc):
                return []
            raise

    def texts(self, words):
        """Static texts whose value carries `words`."""
        return self.find_all(words, role='AXStaticText', by='--value')

    def script(self, text, timeout=60):
        """One AppleScript in the guest through ax.sh; its answer without ax.sh's timing lines."""
        out = command([HERE / 'ax.sh', self.vm, text], timeout)
        return '\n'.join(l for l in out.splitlines() if not l.startswith('{')).strip()

    def app_pid(self):
        state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / self.vm
        return int((state / 'app.pid').read_text().strip())

    def front(self):
        """The app under test frontmost, by its pid (other apps' windows were opened over it)."""
        self.script('tell application "System Events" to set frontmost of (first process whose unix id is %d) to true'
                    % self.app_pid())
        time.sleep(0.8)

    def clipboard(self):
        return self.script('the clipboard as text')

    def close_panel(self):
        if self.present('Close the output panel'):
            self.press('Close the output panel')
            time.sleep(1.2)

    def to_list(self):
        """The open panel back at its list (Escape steps a file view back, §6.8)."""
        if self.present('All output'):
            self.press('All output')
            time.sleep(1.2)

    def divider_x(self):
        found = self.find_all('Output panel width')
        return found[0]['x'] if found else None

    def in_panel(self, nodes):
        left = self.divider_x()
        return [n for n in nodes if left is not None and n['x'] >= left]

    def outside_panel(self, nodes):
        left = self.divider_x()
        return [n for n in nodes if left is None or n['x'] + n['w'] <= left]

    def empty(self):
        """§6.7's empty state, on the thread before anything is written: both Output buttons are
        named for it and the panel says it, in both themes."""
        evidence, note = self.observed('empty')
        self.wait_for('nothing produced yet', role='AXCheckBox', seconds=60)
        buttons = self.find_all('nothing produced yet', role='AXCheckBox')
        note(buttons=buttons)
        self.press('nothing produced yet', role='AXCheckBox')
        self.wait_for('Close the output panel', seconds=20)
        time.sleep(1.5)
        line = self.texts('has produced a file yet')
        note(empty_line=line, head=self.texts('Nothing produced yet'))
        note(shots=self.flip_theme('empty'))
        self.close_panel()
        if len(buttons) != 2:
            raise StepFailed('expected two Output buttons named "nothing produced yet", found %d' % len(buttons))
        if not line:
            raise StepFailed('the panel did not say "has produced a file yet"')
        return evidence

    def csv(self):
        """A CSV previews as a table inside the panel, and Markdown's Preview | Source switch
        works both ways, each photographed in both themes."""
        evidence, note = self.observed('csv')
        # A long conversation with the panel open makes a whole-window search slow: the first
        # candidate 38 run's Approve search outlived ax.sh's 20 s and ended this step.
        os.environ['TESTVM_AX_TIMEOUT'] = '35'
        turn, sent = self.send(CSV_TASK)
        end = time.monotonic() + self.a.within
        rows, slow = [], []
        while time.monotonic() < end:
            rows = [r for r in self.record() if r.get('path', '').endswith('/' + CSV_NAME)]
            if rows:
                break
            try:
                self.approve_pending(sent)
            except (StepFailed, subprocess.TimeoutExpired) as exc:
                slow.append(str(exc)[-200:])
                note(approve_search_failures=slow)
            time.sleep(5)
        self.save_record('record-csv.jsonl')
        note(turn=turn, turn_story=self.turn_story(turn), rows=rows)
        if not rows:
            raise StepFailed('no row for %s reached the record within %d s' % (CSV_NAME, self.a.within))
        failures = []
        self.open_panel()
        self.to_list()
        self.wait_for(CSV_NAME, seconds=20)
        self.press(CSV_NAME)
        self.wait_for('All output', seconds=20)
        time.sleep(3)
        table = self.find_all(CSV_NAME + ', the first rows')
        cells = self.texts('North')
        note(table=table, cell_north=cells, csv_shots=self.flip_theme('preview-csv'))
        if not table:
            failures.append('no table named "%s, the first rows" in its view' % CSV_NAME)
        if not cells:
            failures.append('the table does not show its cell "North"')
        self.to_list()
        # Markdown: Preview | Source.
        self.wait_for('panel-check.md', seconds=20)
        self.press('panel-check.md')
        self.wait_for('All output', seconds=20)
        time.sleep(2)
        note(md_preview_heading=self.heading('Panel check'))
        source_role = self.press_any('Source', ['AXCheckBox', 'AXToggle', 'AXButton'])
        time.sleep(1.5)
        raw = self.texts('# Panel check')
        note(source_role=source_role, source_text=raw, source_shots=self.flip_theme('md-source'))
        if not raw:
            failures.append('Source did not show the file\'s text "# Panel check"')
        self.press_any('Preview', ['AXCheckBox', 'AXToggle', 'AXButton'])
        time.sleep(1.5)
        back = self.heading('Panel check')
        note(preview_again_heading=back, raw_after_preview=bool(self.texts('# Panel check')))
        self.shot('md-preview-again.png')
        if back is not True:
            failures.append('Preview did not bring the heading "Panel check" back')
        self.to_list()
        if failures:
            raise StepFailed('; '.join(failures))
        return evidence

    def buttons(self):
        """Both Output buttons carry the count and each opens the panel; then the list, as a
        person reads it: every recorded file a row, its words, its height in the list."""
        evidence, note = self.observed('buttons')
        self.close_panel()
        found = self.find_all('from this thread', role='AXCheckBox')
        note(buttons=found)
        if len(found) != 2:
            raise StepFailed('expected two Output buttons, found %d: %s' % (len(found), json.dumps(found)))
        names = {n.get('desc') or n.get('title') for n in found}
        presses = []
        for nth in range(2):
            node = self.find_all('from this thread', role='AXCheckBox')[nth]
            where = 'top' if node['y'] == min(n['y'] for n in found) else 'bottom'
            self.ax('click', '--title', 'from this thread', '--role', 'AXCheckBox', '--contains', '--nth', str(nth))
            self.wait_for('Close the output panel', seconds=20)
            time.sleep(1.5)
            head = self.in_panel(self.texts('from this thread'))
            presses.append({'nth': nth, 'button': where, 'name': node.get('desc') or node.get('title'),
                            'panel_head': [h.get('value') for h in head]})
            note(presses=presses)
            self.shot('buttons-%s.png' % where)
            self.close_panel()
        # The list, opened from the top button.
        self.open_panel()
        self.to_list()
        time.sleep(1)
        listed = project(self.record())
        rows = {}
        for key in listed:
            name = Path(key).name
            hits = self.in_panel(self.find_all(name, role='AXButton'))
            rows[key] = [{k: h.get(k) for k in ('title', 'desc', 'x', 'y', 'w', 'h')} for h in hits]
        order = sorted(((r[0]['y'], Path(k).name) for k, r in rows.items() if r), key=lambda t: t[0])
        newest = {k: max(r.get('at', 0) for r in v) for k, v in listed.items()}
        turns = {k: v[-1].get('turnId') for k, v in listed.items()}
        note(names=sorted(names), listed=sorted(listed), rows=rows, order_by_height=order,
             newest_at={Path(k).name: newest[k] for k in listed}, turn_of={Path(k).name: turns[k] for k in listed},
             workers=[h.get('value') for h in self.in_panel(self.texts('by worker'))],
             group_words=[h.get('value') for h in self.in_panel(self.texts('Today'))])
        self.shot('buttons-list.png')
        failures = []
        if len(names) != 1:
            failures.append('the two buttons are named differently: %s' % sorted(names))
        for p in presses:
            if not p['panel_head']:
                failures.append('the %s button did not open the panel on its list' % p['button'])
        missing = [Path(k).name for k, r in rows.items() if not r]
        if missing:
            failures.append('listed in the record but no row in the panel: %s' % missing)
        if failures:
            raise StepFailed('; '.join(failures))
        return evidence

    def link(self):
        """A file link in the conversation opens that file in the panel (§6.5)."""
        evidence, note = self.observed('link')
        self.close_panel()
        target = None
        for name in (ATTACH_NAME, CSV_NAME, 'preview-page.png', 'panel-check.md'):
            links = self.find_all(name, role='AXButton')
            if links:
                target = name
                break
        note(name=target, links=links if target else [])
        if not target:
            raise StepFailed('no file link in the conversation names any file this walk wrote')
        lowest = max(range(len(links)), key=lambda i: links[i]['y'])
        self.ax('click', '--title', target, '--role', 'AXButton', '--contains', '--nth', str(lowest))
        self.wait_for('Close the output panel', seconds=20)
        time.sleep(2)
        on = self.present('All output')
        head = self.in_panel(self.texts(target))
        note(pressed=links[lowest], file_view=on, panel_names_it=[h.get('value') for h in head])
        self.shot('link-opened.png')
        self.to_list()
        if not on or not head:
            raise StepFailed('the link did not open %s in the panel (file view %s, named %s)' % (target, on, bool(head)))
        return evidence

    def menu_items(self):
        """Every menu item on screen: its words, whether it is enabled and its AXHelp (the
        `title` a disabled action carries as its reason)."""
        try:
            found = [n for n in self.ax('find', '--role', 'AXMenuItem') if 'x' in n and not n.get('meta')]
        except StepFailed as exc:
            if 'notfound' in str(exc) or 'nothing matched' in str(exc):
                return []
            raise
        return [{k: m.get(k) for k in ('title', 'desc', 'enabled', 'help', 'x', 'y')} for m in found]

    def actions(self):
        """S6's actions from every entrance a person has: the row's Open, the file view's ▾ for
        Open with, the row's ⋯ for Show in Finder, the row's right-click and the file view's ⋯
        for Copy path; then a file that is gone, and the reasons its actions give."""
        evidence, note = self.observed('actions')
        failures = []
        listed = project(self.record())
        path_of = {Path(k).name: k for k in listed}
        png, md = 'preview-page.png', 'panel-check.md'
        self.open_panel()
        self.to_list()
        # 1. Open: the row's own Open (hover action), by its name.
        before = self.windows()
        try:
            self.press('Open ' + png)
            after = self.wait_for_window(lambda p, w: png in w)
            opened = [(p, w) for p, w in after if png in w and (p, w) not in before]
            note(open_pressed=True, open_windows=after)
            self.shot('actions-1-open.png')
            if not opened:
                failures.append('Open: no window named for %s appeared' % png)
            # The app it opened is left to the guest's own cleanup: an Apple Event to quit it
            # needs a consent the guest does not grant. The app under test comes back to the front.
        except (StepFailed, subprocess.TimeoutExpired) as exc:
            failures.append('Open: ' + str(exc)[:300])
        self.front()
        # 2. Open with: the file view's ▾ lists the other apps.
        try:
            self.press(png)
            self.wait_for('All output', seconds=20)
            time.sleep(2)
            role = self.press_any('Other ways to open', ['AXPopUpButton', 'AXMenuButton', 'AXButton'])
            time.sleep(1)
            items = self.menu_items()
            note(open_menu_role=role, open_menu=items)
            self.shot('actions-2-open-with-menu.png')
            others = [i for i in items if (i.get('title') or i.get('desc') or '').startswith('Open in ')][1:]
            if not others:
                failures.append('Open with: the ▾ offered no app beside the default: %s' % [i.get('title') for i in items])
                self.script('tell application "System Events" to key code 53')
            else:
                label = others[0].get('title') or others[0].get('desc')
                app = label[len('Open in '):]
                before = self.windows()
                self.press(label, role='AXMenuItem')
                after = self.wait_for_window(lambda p, w: p == app and png in w)
                note(open_with=label, open_with_windows=after)
                self.shot('actions-3-open-with.png')
                if not any(p == app and png in w and (p, w) not in before for p, w in after):
                    failures.append('Open with %s: no window of %s appeared' % (app, app))
        except (StepFailed, subprocess.TimeoutExpired) as exc:
            failures.append('Open with: ' + str(exc)[:300])
        self.front()
        self.to_list()
        # 3. Show in Finder, from the row's ⋯.
        try:
            folder = Path(path_of.get(png, '')).parent.name
            self.press_any('More actions for ' + png, ['AXPopUpButton', 'AXMenuButton', 'AXButton'])
            time.sleep(1)
            note(row_menu=self.menu_items())
            self.press('Show in Finder', role='AXMenuItem')
            after = self.wait_for_window(lambda p, w: p == 'Finder' and w == folder)
            note(finder_windows=after, finder_folder=folder)
            self.shot('actions-4-show-in-finder.png')
            if not any(p == 'Finder' and w == folder for p, w in after):
                failures.append('Show in Finder: no Finder window for %s' % folder)
            # Not closed with an Apple Event to Finder: the guest grants none, and asking raises a
            # consent prompt that holds the call open (the first candidate 38 run timed out here).
            # The app is brought back to the front below instead.
        except (StepFailed, subprocess.TimeoutExpired) as exc:
            failures.append('Show in Finder: ' + str(exc)[:300])
        self.front()
        self.to_list()
        # 4. Copy path, from the row's right-click (a real right button).
        try:
            self.script('set the clipboard to "seed"')
            row = [n for n in self.in_panel(self.find_all(md, role='AXButton')) if 'More actions' not in (n.get('title') or '')
                   and not (n.get('desc') or '').startswith(('Open ', 'More actions'))]
            note(right_click_row=row[:1])
            at = '%.0f,%.0f' % (row[0]['x'] + 40, row[0]['y'] + row[0]['h'] / 2)
            note(right_click=command([HERE / 'pointer-drag.sh', self.vm, at, at, '--right'], 90).strip().splitlines()[-1])
            time.sleep(1)
            note(context_menu=self.menu_items())
            self.shot('actions-5-right-click.png')
            self.press('Copy path', role='AXMenuItem')
            time.sleep(1)
            got = self.clipboard()
            note(copied_from_right_click=got, recorded_path=path_of.get(md))
            if got != path_of.get(md):
                failures.append('Copy path (right-click): the clipboard holds %r, not the recorded path' % got)
        except (StepFailed, IndexError, subprocess.TimeoutExpired) as exc:
            failures.append('right-click Copy path: ' + str(exc)[:300])
        # 5. The file view's ⋯, and its Copy path.
        try:
            self.script('set the clipboard to "seed"')
            self.press(md)
            self.wait_for('All output', seconds=20)
            time.sleep(1.5)
            self.press_any('More actions', ['AXPopUpButton', 'AXMenuButton', 'AXButton'], contains=False)
            time.sleep(1)
            note(file_view_menu=self.menu_items())
            self.shot('actions-6-file-view-menu.png')
            self.press('Copy path', role='AXMenuItem')
            time.sleep(1)
            got = self.clipboard()
            note(copied_from_file_view=got)
            if got != path_of.get(md):
                failures.append('Copy path (file view ⋯): the clipboard holds %r' % got)
        except (StepFailed, subprocess.TimeoutExpired) as exc:
            failures.append('file view ⋯ Copy path: ' + str(exc)[:300])
        self.to_list()
        self.front()
        if failures:
            raise StepFailed('; '.join(failures))
        return evidence

    def missing(self):
        """A recorded file that is gone (§6.7): deleted in the guest, and the deletion proven,
        then the panel reopened. Its row says so, and its actions are off with the reason as
        their tooltip (AXHelp), from the row's ⋯ and in its own view; Copy path stays on."""
        evidence, note = self.observed('missing')
        failures = []
        gone = next((k for k in project(self.record()) if Path(k).name == CSV_NAME), None)
        if not gone:
            raise StepFailed('no %s in the record: run the csv step first' % CSV_NAME)
        before = self.exists_in_guest(gone)
        guest(self.vm, 'rm -f ' + shlex.quote(gone), 60)
        after = self.exists_in_guest(gone)
        note(path=gone, existed_before=before, exists_after_rm=after)
        if after:
            raise StepFailed('the file could not be deleted in the guest: ' + gone)
        self.close_panel()
        self.open_panel()
        self.to_list()
        # The row's own words are not separate texts in the tree (a role="button" row's children
        # are presentational), so the panel's head, which counts the gone files, is what is read:
        # "N files from this thread · 1 no longer where it was written". The frame shows the row.
        line, end = [], time.monotonic() + 20
        while time.monotonic() < end and not line:
            line = [h.get('value') for h in self.in_panel(self.texts('no longer where it was written'))
                    if 'from this thread' in (h.get('value') or '')]
            time.sleep(1)
        head = [h.get('value') for h in self.in_panel(self.texts('from this thread'))]
        note(missing_line=line, panel_head=head)
        self.shot('missing-1-list.png')
        if not line:
            failures.append('the panel does not count the gone file 20 s after it reopened: %s' % head)

        def row_menu(tag):
            """The row's ⋯, its items read and photographed; the failures it shows."""
            self.to_list()
            self.press_any('More actions for ' + CSV_NAME, ['AXPopUpButton', 'AXMenuButton', 'AXButton'])
            time.sleep(1)
            items = self.menu_items()
            note(**{tag + '_row_menu': items})
            self.shot('missing-%s-row-menu.png' % tag)
            self.script('tell application "System Events" to key code 53')
            time.sleep(1)
            found = []

            def item(label):
                return next((i for i in items if (i.get('title') or i.get('desc') or '').startswith(label)), None)
            for label in ('Open', 'Show in Finder', 'Save a copy', 'Add to chat'):
                i = item(label)
                if not i:
                    found.append('%s: no %s item' % (tag, label))
                elif i.get('enabled') is not False or i.get('help') != MISSING_SENTENCE:
                    found.append('%s: %s is enabled=%s with reason %r' % (tag, label, i.get('enabled'), i.get('help')))
            copy = item('Copy path')
            if not copy or copy.get('enabled') is False:
                found.append('%s: Copy path should stay on: %s' % (tag, copy))
            return found

        def file_view(tag):
            self.to_list()
            self.press(CSV_NAME)
            self.wait_for('All output', seconds=20)
            time.sleep(2)
            sentence = self.in_panel(self.texts('no longer where it was written'))
            opens = [{k: n.get(k) for k in ('title', 'desc', 'enabled', 'help')}
                     for n in self.in_panel(self.find_all('Open', role='AXButton'))]
            note(**{tag + '_view_sentence': [s.get('value') for s in sentence], tag + '_view_open_controls': opens})
            self.shot('missing-%s-file-view.png' % tag)
            found = []
            if not any(MISSING_SENTENCE in (s.get('value') or '') for s in sentence):
                found.append('%s: the file view does not say the §6.7 sentence' % tag)
            if any(o.get('enabled') for o in opens if (o.get('title') or '').startswith('Open in') or o.get('title') == 'Open'):
                found.append('%s: the file view\'s Open is lit beside the sentence that the file is gone' % tag)
            return found

        # A. As the panel shows it after a reopen, before anything tells it the file is gone.
        failures += row_menu('a')
        failures += file_view('a')
        # B. After the app has been told: its own Open answers that the file is gone (a press a
        # person would make), which is the one thing that makes the panel read its list again.
        learned = None
        try:
            opener = next((o['title'] for o in evidence.get('a_view_open_controls', [])
                           if (o.get('title') or '').startswith('Open')), None)
            if opener:
                self.press(opener)
                time.sleep(2)
                learned = [h.get('value') for h in self.texts('no longer where it was written')]
                self.shot('missing-b-after-open.png')
        except (StepFailed, subprocess.TimeoutExpired) as exc:
            learned = 'the press failed: ' + str(exc)[:200]
        note(b_pressed_open_and_heard=learned)
        self.to_list()
        time.sleep(1)
        b_line = [h.get('value') for h in self.in_panel(self.texts('no longer where it was written'))
                  if 'from this thread' in (h.get('value') or '')]
        note(b_missing_line=b_line)
        if not b_line:
            failures.append('b: after Open answered, the panel still does not count the gone file')
        failures += row_menu('b')
        failures += file_view('b')
        self.to_list()
        if failures:
            raise StepFailed('; '.join(failures))
        return evidence

    def menus(self):
        """The row's ⋯ menu and the file view's ⋯ menu, each open and photographed in both
        themes, for contrast.py (after the panel step: panel-check.md)."""
        evidence, note = self.observed('menus')
        self.open_panel()
        self.to_list()
        self.press_any('More actions for panel-check.md', ['AXPopUpButton', 'AXMenuButton', 'AXButton'])
        time.sleep(1)
        note(row_menu=self.menu_items(), row_shots=self.flip_theme('menu-row'))
        self.script('tell application "System Events" to key code 53')
        time.sleep(1)
        self.press('panel-check.md')
        self.wait_for('All output', seconds=20)
        time.sleep(1.5)
        self.press_any('More actions', ['AXPopUpButton', 'AXMenuButton', 'AXButton'], contains=False)
        time.sleep(1)
        note(file_menu=self.menu_items(), file_shots=self.flip_theme('menu-file'))
        self.script('tell application "System Events" to key code 53')
        time.sleep(1)
        self.to_list()
        if not evidence['row_menu'] or not evidence['file_menu']:
            raise StepFailed('a menu did not open: row %d items, file view %d items'
                             % (len(evidence['row_menu']), len(evidence['file_menu'])))
        return evidence

    def overlap(self):
        """One right-hand pane at a time (PRD §6.1), from the other side: with the Output panel
        open, the work summary ("Under the hood", the chip under the conversation) is opened the
        way a person approving a job opens it. Records whether the Output panel is still open
        beside it, and photographs it. Needs a job on the thread (run after backend-worker)."""
        evidence, note = self.observed('overlap')
        self.open_panel()
        self.to_list()
        time.sleep(1)
        if not self.present('Open the work summary'):
            note(work_summary_control=False)
            raise StepFailed('no "Open the work summary" control on this thread: run after backend-worker')
        self.press('Open the work summary')
        time.sleep(2)
        output_open = self.present('Close the output panel')
        close = self.find_all('Close the output panel')
        back = self.find_all('back to Rich')
        note(output_still_open=output_open, output_close=close[:1], slide_over_back=back[:1])
        shots = self.flip_theme('overlap')
        note(shots=shots)
        if back:
            self.press('back to Rich')
            time.sleep(1)
        if output_open:
            raise StepFailed('the Output panel stayed open under the work summary: two right-hand panes at once')
        return evidence

    def job_question(self):
        """Walk 38, D8: a background job that stopped at a question is not drawn as a turn a quit
        cut off. The app is never relaunched in this run, so the quit card has no true place on the
        conversation at all; the job's question card must be there (the positive control), and
        neither the quit card nor a "Status unavailable" row may be."""
        evidence, note = self.observed('job-question')
        # Every read in this step gets the long deadline, the first ones included: on a loaded host
        # (2026-10-06, walk-164baac388a9, host 95% busy) close_panel's find outlived the 20 s default.
        os.environ['TESTVM_AX_TIMEOUT'] = '150'
        self.close_panel()
        if self.present('back to Rich'):
            self.press('back to Rich')
            time.sleep(1)
        jobs = [a for a in self.records() if a.get('thread_id') == self.facts['thread'] and a.get('obligation_id')]
        blocked = [{k: a.get(k) for k in ('id', 'kind', 'state', 'detail')} for a in jobs if a.get('state') == 'blocked']
        note(app_pid=self.app_pid(), jobs=len(jobs), blocked_jobs=blocked)
        seen = self.conversation_read()
        note(asked_by='the job' if seen['question_cards'] else None, **seen)
        if not seen['question_cards']:
            if not jobs:
                raise StepFailed('no job on this thread: run after backend-worker')
            job = sorted(jobs, key=lambda a: (a.get('state') == 'blocked', a.get('registered_at_ms', 0)))[-1]
            note(asked_by='the walk, through the job question tool', ask=self.ask_as_the_job(job))
            end = time.monotonic() + 30
            while time.monotonic() < end and not seen['question_cards']:
                time.sleep(3)
                seen = self.conversation_read()
            note(**seen)
        # The tree reads above are the verdict; the photograph illustrates them.
        self.shot('job-question.png')
        note(shots=['job-question.png'])
        if seen['quit_card'] or seen['status_unavailable']:
            raise StepFailed('a turn is drawn as cut off by a quit while the app never closed: %s'
                             % json.dumps(seen['quit_card'] + seen['status_unavailable']))
        if not seen['question_cards']:
            raise StepFailed("the job's question card never reached the conversation")
        return evidence

    def conversation_read(self):
        """ONE read of the whole window, not one find per word: after backend-worker the
        conversation is long, and the first run of job-question (2026-10-06, walk-647cf54f10ca) had
        a single find for "Other answer" outlive ax.sh's 20 s guest deadline (exit 124). A tree read
        past its node cap refuses as incomplete rather than answering "absent". The tree holds the
        whole conversation, scrolled or not (the wrote step reads rows at negative y)."""
        os.environ['TESTVM_AX_TIMEOUT'] = '150'
        nodes = [n for n in self.ax('tree', '--max', '30000', timeout=200) if 'x' in n and not n.get('meta')]
        words = lambda n: ' '.join(str(n.get(k) or '') for k in ('title', 'desc', 'value'))  # noqa: E731
        return {'nodes_read': len(nodes),
                'question_cards': len([n for n in nodes if n.get('role') == 'AXButton' and 'Other answer' in words(n)]),
                'quit_card': [words(n).strip() for n in nodes if QUIT_CARD in words(n)],
                'status_unavailable': [words(n).strip() for n in nodes if STATUS_UNAVAILABLE in words(n)]}

    def ask_as_the_job(self, job):
        """The job's own question tool, asked once. A back end asks through the app's
        `--questions-mcp` server with the scope `native.rs` `prepare_question_scope` writes for a
        work lease: turn and asker are the job's OBLIGATION. Whether the model chooses to ask is
        not what D8 is about (the second run of this step, walk-dfbda3bd2dfa, had the job land
        without asking), so when it did not, the walk makes the same call through the same binary
        into the same store, and the evidence says which happened."""
        exe = guest(self.vm, 'ps -o comm= -p %d' % self.app_pid(), 60).strip()
        if not (exe.startswith(self.payload) and exe.endswith('/richos-tauri')):
            raise StepFailed('the recorded app pid is not this payload\'s app: ' + exe)
        scope = {'context': {'root': self.data + '/engine-state', 'entity_id': job['entity_id'],
                             'thread_id': job['thread_id'], 'turn_id': job['obligation_id'],
                             'asker': job['obligation_id'], 'session_id': 'output-walk-job-question',
                             'engine': None, 'entity_root': None},
                 'actions_allowed': True, 'answer_method': 'typed', 'surface': 'mac'}
        question = {'text': 'Which name should the walk file get?',
                    'options': [{'label': 'Name it walk-a.md', 'description': 'The first name.'},
                                {'label': 'Name it walk-b.md', 'description': 'The second name.'}]}
        frames = ''.join(json.dumps(f) + '\n' for f in (
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
             'params': {'name': 'ask', 'arguments': {'questions': [question]}}}))
        path = '/tmp/output-walk-job-question.scope.json'
        out = guest(self.vm, 'printf %s ' + shlex.quote(json.dumps(scope)) + ' > ' + path + ' && printf %s '
                    + shlex.quote(frames) + ' | ' + shlex.quote(exe) + ' --questions-mcp ' + path, 60)
        replies = [json.loads(line) for line in out.splitlines() if line.startswith('{')]
        result = next((r for r in replies if r.get('id') == 2), {}).get('result') or {}
        text = (result.get('content') or [{}])[0].get('text', '')
        if result.get('isError') or '"recorded":true' not in text:
            raise StepFailed('the job question tool did not record the question: ' + out[-400:])
        return {'executable': exe, 'obligation': job['obligation_id'], 'recorded': True}

    def wrote(self):
        """Every *Wrote N files* in the conversation, pressed in turn: the panel opens on that turn
        and the app's frame never moves (nightly a1a26a615: one press scrolled the shell 417 px)."""
        evidence, note = self.observed('wrote')
        self.close_panel()
        found = self.find_all('Wrote ', role='AXButton')
        note(found=[{k: n.get(k) for k in ('title', 'desc', 'y')} for n in found])
        if not found:
            raise StepFailed('no "Wrote N files" in the conversation')
        presses, failures = [], []
        for nth in range(len(found)):
            toggle0 = self.node('Hide the sidebar')
            composer0 = self.node('Message to Rich', role='AXTextArea')
            self.ax('click', '--title', 'Wrote ', '--role', 'AXButton', '--contains', '--nth', str(nth))
            self.wait_for('Close the output panel', seconds=20)
            time.sleep(1.5)
            toggle1 = self.node('Hide the sidebar')
            composer1 = self.node('Message to Rich', role='AXTextArea')
            close = self.node('Close the output panel')
            p = {'nth': nth, 'label': found[nth].get('title') or found[nth].get('desc'),
                 'toggle_moved': round(toggle1['y'] - toggle0['y'], 1),
                 'composer_bottom_moved': round((composer1['y'] + composer1['h']) - (composer0['y'] + composer0['h']), 1),
                 'close_level_gap': round(abs(close['y'] - toggle1['y']), 1)}
            presses.append(p)
            note(presses=presses)
            self.shot('wrote-%d.png' % (nth + 1))
            if abs(p['toggle_moved']) > 4 or abs(p['composer_bottom_moved']) > 4 or p['close_level_gap'] > 40:
                failures.append('press %d moved the frame: %s' % (nth + 1, json.dumps(p)))
            self.close_panel()
        if failures:
            raise StepFailed('; '.join(failures))
        return evidence

    def theme_flash(self):
        """With the panel open, the guest's appearance flips while timeline.py photographs the
        panel in the guest, on one clock. The frames come back for contrast.py, frame by frame."""
        evidence, note = self.observed('theme-flash')
        self.open_panel()
        self.to_list()
        time.sleep(1)
        left = self.divider_x()
        close = self.node('Close the output panel')
        x, y = int(left), int(max(0, close['y'] - 24))
        w, h = int(close['x'] + close['w'] + 24 - left), 560
        remote = self.payload + '/qa'
        qa = HERE.parent / 'qa'
        guest(self.vm, 'mkdir -p ' + shlex.quote(remote + '/lib'), 60)
        command([HERE / 'guest.sh', self.vm, '--push', qa / 'timeline.py', remote + '/timeline.py'], 120)
        for lib in ('qaimg.py', 'qaocr.py'):
            command([HERE / 'guest.sh', self.vm, '--push', qa / 'lib' / lib, remote + '/lib/' + lib], 120)
        first_dark = 'Dark' in guest(self.vm, 'defaults read -g AppleInterfaceStyle 2>/dev/null || true')
        note(region=[x, y, w, h], first_theme='dark' if first_dark else 'light',
             nodes={'head': self.in_panel(self.texts('from this thread'))[:1], 'close': close})
        flash = remote + '/flash'
        guest(self.vm, '(cd {r} && python3 timeline.py capture {f} 7 --region {x},{y},{w},{h} --wait-only --baseline 1 '
                       '> {r}/flash.log 2>&1; echo $? > {r}/flash.exit) >/dev/null 2>&1 &'.format(
                           r=shlex.quote(remote), f=shlex.quote(flash), x=x, y=y, w=w, h=h), 60)
        time.sleep(2.5)
        command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to tell appearance preferences '
                 'to set dark mode to ' + ('false' if first_dark else 'true')], 60)
        flipped = self.clock()
        end = time.monotonic() + 40
        while time.monotonic() < end and not self.exists_in_guest(remote + '/flash.exit'):
            time.sleep(1)
        log = guest(self.vm, 'cat ' + shlex.quote(remote + '/flash.log') + ' ' + shlex.quote(remote + '/flash.exit')
                    + ' 2>/dev/null || true', 60)
        command([HERE / 'ax.sh', self.vm, 'tell application "System Events" to tell appearance preferences '
                 'to set dark mode to ' + ('true' if first_dark else 'false')], 60)
        guest(self.vm, 'cd {r} && tar -czf flash.tgz flash'.format(r=shlex.quote(remote)), 120)
        command([HERE / 'guest.sh', self.vm, '--pull', remote + '/flash.tgz', self.out / 'flash.tgz'], 120)
        note(flipped_guest_ms=round(flipped), capture_log=log[-3000:])
        if not (self.out / 'flash.tgz').is_file():
            raise StepFailed('the frames did not come back from the guest')
        return evidence

    def sidebar(self):
        """S8 as a person uses it: the sidebar away by its button (the conversation takes the
        width) and back, ⌘⇧S both ways, and hidden across a relaunch."""
        evidence, note = self.observed('sidebar')
        failures = []
        self.close_panel()
        composer0 = self.node('Message to Rich', role='AXTextArea')
        rail0 = self.find_all('Entities and threads')
        self.press_named('Hide the sidebar')
        time.sleep(1.2)
        composer1 = self.node('Message to Rich', role='AXTextArea')
        rail1 = [n for n in self.find_all('Entities and threads') if n['w'] > 0]
        note(composer_shown=composer0, rail_shown=rail0[:1], composer_hidden=composer1, rail_hidden=rail1[:1],
             hidden_shots=self.flip_theme('sidebar-hidden'))
        if not self.present('Show the sidebar'):
            failures.append('the toggle does not offer "Show the sidebar" after hiding it')
        # The conversation's column is centered with a reading width (the composer keeps its own
        # width), so the stage taking the rail's room shows as the column moving left by half of it.
        shift = composer0['x'] - composer1['x']
        note(column_shift=shift)
        if rail1 or not rail0 or abs(shift - rail0[0]['w'] / 2) > 24:
            failures.append('the conversation did not take the rail\'s width: the column moved %.0f px, '
                            'the rail was %s px wide and is %s' % (shift, rail0[0]['w'] if rail0 else '?',
                                                                    'still there' if rail1 else 'gone'))
        # ⌘⇧S, both ways, sent to the app's own pid frontmost.
        keys = []
        for want in ('Hide the sidebar', 'Show the sidebar'):
            self.front()
            self.script('tell application "System Events"\n'
                        '  if (unix id of (first process whose frontmost is true)) is not %d then error "not frontmost"\n'
                        '  keystroke "s" using {command down, shift down}\n'
                        'end tell' % self.app_pid())
            time.sleep(1.2)
            keys.append({'expect': want, 'present': self.present(want)})
        note(keyboard=keys)
        failures += ['⌘⇧S did not toggle to offer "%s"' % k['expect'] for k in keys if not k['present']]
        # Hidden across a relaunch.
        if not self.present('Show the sidebar'):
            self.press_named('Hide the sidebar')
            time.sleep(1.2)
        # The relaunch, by relaunch.py, and then the way a person comes back: the home screen's
        # "Talk to Rich" door, which lands in the conversation. (CommandWalk.relaunch presses the
        # thread in the rail, which is not there while the sidebar is hidden: the first run failed
        # on that press, not on the app.)
        from relaunch import relaunch
        note(relaunched=relaunch(self.vm))
        seen, end = [], time.monotonic() + self.a.relaunch_within
        while time.monotonic() < end:
            s = {'composer': self.present('Message to Rich', role='AXTextArea'),
                 'show_sidebar': self.present('Show the sidebar'), 'hide_sidebar': self.present('Hide the sidebar'),
                 'home_door': self.present('Talk to Rich')}
            seen.append(s)
            note(after_relaunch=seen)
            if s['composer'] and (s['show_sidebar'] or s['hide_sidebar']):
                break
            if s['home_door'] and not s['composer']:
                self.shot('sidebar-relaunch-home.png')
                self.press('Talk to Rich')
                time.sleep(3)
                continue
            time.sleep(4)
        time.sleep(2)
        kept = self.present('Show the sidebar')
        note(hidden_after_relaunch=kept)
        self.shot('sidebar-after-relaunch.png')
        if not kept:
            failures.append('the sidebar came back shown after the relaunch')
        self.press_named('Show the sidebar')
        time.sleep(1.2)
        note(shown_again=self.present('Hide the sidebar'))
        self.shot('sidebar-shown-again.png')
        if failures:
            raise StepFailed('; '.join(failures))
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
    p.add_argument('--relaunch-within', type=float, default=120,
                   help='sidebar: seconds for the composer to come back after the relaunch')
    p.add_argument('--steps', default=','.join(s for s in STEPS
                                               if s not in ('open-reveal', 'panel', 'md-view', 'previews', 'save-copy', 'attach', 'pull')
                                               and s not in CANDIDATE_STEPS),
                   help='default: every step but open-reveal (alone, with --no-app) and the panel steps, '
                        'which run together after identity, first-run and connect: '
                        '--steps identity,first-run,connect,tools,panel,previews,save-copy,attach,pull '
                        '(S4 panel, S5 previews, S6 save-copy, S7 attach, S9 pull); md-view runs after panel')
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
