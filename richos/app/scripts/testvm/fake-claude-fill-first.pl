#!/usr/bin/perl
# A fake `claude` for the fill-first VM check. It answers what RichOS asks of the binary:
# `auth status/login/logout`, `--version`, the control-only quota probe (`get_usage`) and
# plain turns, reading each account's figures from a file the walk writes:
#   Account 1 (no CLAUDE_CONFIG_DIR of RichOS's own): /Users/admin/fill-first/usage-1.json
#   an added account: <its CLAUDE_CONFIG_DIR>/usage.json
# A usage file is {"five": N, "weekly": N}, optionally with "five_at" and "week_at" (epoch
# seconds) for when each window resets; without them a window resets 3 h / 4 d after this
# process started. A usage file {"null": true} answers get_usage as Claude Code 2.1.289 does
# some of the time: rate_limits_available true and rate_limits null (walk of nightly 36, D1,
# qa/usage-shape.sh), and a turn then streams no rate_limit_event. While /Users/admin/fill-first/slow exists, a turn is held open before it
# answers (at most 10 minutes), so a walk can photograph a turn in progress. Only the user's
# own turns are held: the app's internal turns (the handoff summary and the re-prime of a new
# lease, both "[INTERNAL ...") answer at once, because a lease is installed only after its
# priming answers (spine.rs rotate_lease), and holding the priming kept the conversation on
# the old lease's session while the walk photographed it (2026-10-05 run, shot 4).
#
# A LEASE'S EVIDENCE. Claude Code's own SessionStart hook (engine app-evidence.py) creates
# <data>/engine-state/evidence/<session>/ with .lock and callbacks.jsonl; the app reads it
# for the working agents and refuses a turn end it cannot read (native.rs worker settlement:
# "Stopped ... I don't recognize what came back"). This fake runs no hooks, so it writes that
# journal itself, with the same row shape, when it starts as a lease (--session-id), and, while
# /Users/admin/fill-first/agents exists, the provider's rows for one background agent per line
# of that file on the first user turn (SubagentStart and PostToolUse[Agent] "async_launched",
# the rows app_workers.rs reads). /Users/admin/fill-first/reply.txt, when present, is the answer.
# Nothing here reaches a network.
use strict; use warnings; use JSON::PP; use Fcntl qw(:flock); use File::Path qw(make_path);
$| = 1;
# The walk's folder in the guest; RICHOS_FILL_FIRST_DIR moves it for a check off the guest.
my $dir = $ENV{RICHOS_FILL_FIRST_DIR} // '/Users/admin/fill-first';
my $json = JSON::PP->new->canonical;
my $folder = $ENV{CLAUDE_CONFIG_DIR} // '';
my $file = $folder =~ /claude-accounts/ ? "$folder/usage.json" : "$dir/usage-1.json";
# Defaults when the walk has not written a file yet: Account 1 40/30, an added account 10/20,
# so a newly added account never reads as a jump from zero.
my $default = $folder =~ /claude-accounts/ ? { five => 10, weekly => 20 } : { five => 40, weekly => 30 };
sub usage {
  open(my $fh, '<', $file) or return $default;
  local $/; my $text = <$fh>; close $fh;
  return eval { $json->decode($text) } || $default;
}
open(my $log, '>>', "$dir/calls.log");
print $log join(' ', time(), ($folder || 'account-1'), @ARGV), "\n"; close $log;
if (grep { $_ eq '--version' } @ARGV) { print "2.1.288 (Claude Code)\n"; exit 0; }
# WHO EACH FOLDER IS SIGNED IN AS (round 18's "That is the account you already use"): `auth
# status` names an email, as Claude Code's does. Account 1 is account-1@fixture.invalid; an
# added folder is added-<n>@fixture.invalid unless its sign-in wrote another. While
# /Users/admin/fill-first/login-as exists, `auth login` under a folder signs that folder in as
# the address it holds, so a walk can sign in with the account already in use. No network.
if (@ARGV && $ARGV[0] eq 'auth') {
  my ($id) = $folder =~ /claude-accounts\/(\d+)/;
  if (($ARGV[1] // '') eq 'login' && $folder && open(my $as, '<', "$dir/login-as")) {
    my $who = <$as> // ''; close $as; $who =~ s/\s+\z//;
    if (length $who && open(my $out, '>', "$folder/email")) { print $out $who; close $out; }
  }
  if (($ARGV[1] // '') eq 'status') {
    my $email = $folder ? "added-" . ($id // 'x') . '@fixture.invalid' : 'account-1@fixture.invalid';
    if ($folder && open(my $in, '<', "$folder/email")) { my $e = <$in> // ''; close $in; $e =~ s/\s+\z//; $email = $e if length $e; }
    print $json->encode({ loggedIn => JSON::PP::true, configDirectory => $folder, email => $email, orgId => 'fixture-org' }), "\n";
  }
  exit 0;
}
my $five_reset = time() + 3 * 3600; my $week_reset = time() + 4 * 86400;
sub arg_after { my ($flag, $match) = @_; for my $i (0 .. $#ARGV - 1) { return $ARGV[$i + 1] if $ARGV[$i] eq $flag && (!$match || $ARGV[$i + 1] =~ $match); } return undef }
my $session = arg_after('--session-id');
my $profile = arg_after('--plugin-dir', qr{/engine-profiles/});
my $evidence;
if ($session && $profile && $session =~ /\A[A-Za-z0-9_-]{1,128}\z/) {
  (my $data = $profile) =~ s{/engine-profiles/[^/]+/?\z}{};
  $evidence = "$data/engine-state/evidence/$session";
  make_path($evidence, { mode => 0700 });
}
sub journal {  # append callback rows under the journal's lock, as app-evidence.py does
  return unless $evidence;
  open(my $lock, '>>', "$evidence/.lock") or return; flock($lock, LOCK_EX);
  open(my $out, '>>', "$evidence/callbacks.jsonl") or return;
  print $out $json->encode({ schema => 1, callback => { session_id => $session, %$_ } }), "\n" for @_;
  close $out; close $lock;
}
journal({ hook_event_name => 'SessionStart' });
sub iso { my @t = gmtime(shift); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]) }
while (my $line = <STDIN>) {
  my $msg = eval { $json->decode($line) } or next;
  my $type = $msg->{type} // '';
  if ($type eq 'control_request') {
    my $kind = $msg->{request}{subtype} // '';
    my $answer = {};
    if ($kind eq 'get_usage') {
      my $u = usage();
      $answer = $u->{null} ? { rate_limits_available => JSON::PP::true, rate_limits => undef }
        : { rate_limits_available => JSON::PP::true, rate_limits => {
        five_hour => { utilization => $u->{five} + 0, resets_at => iso($u->{five_at} // $five_reset) },
        seven_day => { utilization => $u->{weekly} + 0, resets_at => iso($u->{week_at} // $week_reset) } } };
    }
    print $json->encode({ type => 'control_response', response => { subtype => 'success', request_id => $msg->{request_id}, response => $answer } }), "\n";
  } elsif ($type eq 'user') {
    # Claude Code's startup inventory, with every turn, in the shape testvm/permission-provider.py
    # proved on the real app (the S7 walk). Without it a company conversation's turn is refused
    # before it starts: "The connection did not report whether company interview tools loaded."
    # (native.rs ensure_onboarding_tools_loaded; the 2026-10-05 round-16 walk, relaunch log).
    # These are declarations only; this fake executes none of these tools.
    print $json->encode({ type => 'system', subtype => 'init', model => 'fill-first-fixture',
      plugins => [ { name => 'rich-skills' }, { name => 'richos-app-engine' } ], permissionMode => 'auto',
      tools => [ 'Bash', 'mcp__richos_onboarding__save_company_notes', 'mcp__richos_onboarding__decline_onboarding',
        'mcp__richos_continuity__checkpoint', 'mcp__richos_continuity__inspect',
        'mcp__richos_assignments__record', 'mcp__richos_status__background_work' ] }), "\n";
    my $internal =index($json->encode($msg->{message} // {}), '[INTERNAL') >= 0;
    if (!$internal && $evidence && open(my $names, '<', "$dir/agents")) {
      my @who = grep { length } map { s/\s+\z//r } <$names>; close $names;
      my $seen = '';
      if (open(my $in, '<', "$evidence/callbacks.jsonl")) { local $/; $seen = <$in> // ''; close $in; }
      if ($seen !~ /walk-agent-/) {
        my $n = 0;
        journal(map { $n++; ({ hook_event_name => 'SubagentStart', agent_id => "walk-agent-$n", agent_type => $_ },
          { hook_event_name => 'PostToolUse', tool_name => 'Agent', tool_response => { status => 'async_launched', agentId => "walk-agent-$n" } }) } @who);
      }
    }
    unless ($internal) { for (1 .. 600) { last unless -e "$dir/slow"; sleep 1; } }
    my $u = usage();
    print $json->encode({ type => 'rate_limit_event', rate_limit_info => { status => 'allowed', unifiedWindows => {
      five_hour => { utilization => $u->{five} / 100, resetsAt => $u->{five_at} // $five_reset },
      seven_day => { utilization => $u->{weekly} / 100, resetsAt => $u->{week_at} // $week_reset } } } }), "\n" unless $u->{null};
    my $who = $folder =~ /claude-accounts\/(\d+)/ ? "account $1" : 'Account 1';
    my $text = "Answered on $who.";
    if (!$internal && open(my $r, '<', "$dir/reply.txt")) { local $/; my $t = <$r>; close $r; $text = $t =~ s/\s+\z//r if defined $t && length $t; }
    $text = 'ready' if $internal;
    print $json->encode({ type => 'assistant', message => { role => 'assistant', content => [ { type => 'text', text => $text } ] } }), "\n";
    print $json->encode({ type => 'result', subtype => 'success', stop_reason => 'end_turn', is_error => JSON::PP::false, result => $text }), "\n";
  }
}
