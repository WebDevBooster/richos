#!/usr/bin/perl
# A fake `claude` for the fill-first VM check. It answers what RichOS asks of the binary:
# `auth status/login/logout`, `--version`, the control-only quota probe (`get_usage`) and
# plain turns, reading each account's figures from a file the walk writes:
#   Account 1 (no CLAUDE_CONFIG_DIR of RichOS's own): /Users/admin/fill-first/usage-1.json
#   an added account: <its CLAUDE_CONFIG_DIR>/usage.json
# A usage file is {"five": N, "weekly": N}, optionally with "five_at" and "week_at" (epoch
# seconds) for when each window resets; without them a window resets 3 h / 4 d after this
# process started. While /Users/admin/fill-first/slow exists, a turn is held open before it
# answers (at most 10 minutes), so a walk can photograph a turn in progress.
# Nothing here reaches a network.
use strict; use warnings; use JSON::PP;
$| = 1;
my $json = JSON::PP->new->canonical;
my $folder = $ENV{CLAUDE_CONFIG_DIR} // '';
my $file = $folder =~ /claude-accounts/ ? "$folder/usage.json" : "/Users/admin/fill-first/usage-1.json";
# Defaults when the walk has not written a file yet: Account 1 40/30, an added account 10/20,
# so a newly added account never reads as a jump from zero.
my $default = $folder =~ /claude-accounts/ ? { five => 10, weekly => 20 } : { five => 40, weekly => 30 };
sub usage {
  open(my $fh, '<', $file) or return $default;
  local $/; my $text = <$fh>; close $fh;
  return eval { $json->decode($text) } || $default;
}
open(my $log, '>>', '/Users/admin/fill-first/calls.log');
print $log join(' ', time(), ($folder || 'account-1'), @ARGV), "\n"; close $log;
if (grep { $_ eq '--version' } @ARGV) { print "2.1.288 (Claude Code)\n"; exit 0; }
if (@ARGV && $ARGV[0] eq 'auth') {
  if (($ARGV[1] // '') eq 'status') { print $json->encode({ loggedIn => JSON::PP::true, configDirectory => $folder }), "\n"; }
  exit 0;
}
my $five_reset = time() + 3 * 3600; my $week_reset = time() + 4 * 86400;
sub iso { my @t = gmtime(shift); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]) }
while (my $line = <STDIN>) {
  my $msg = eval { $json->decode($line) } or next;
  my $type = $msg->{type} // '';
  if ($type eq 'control_request') {
    my $kind = $msg->{request}{subtype} // '';
    my $answer = {};
    if ($kind eq 'get_usage') {
      my $u = usage();
      $answer = { rate_limits_available => JSON::PP::true, rate_limits => {
        five_hour => { utilization => $u->{five} + 0, resets_at => iso($u->{five_at} // $five_reset) },
        seven_day => { utilization => $u->{weekly} + 0, resets_at => iso($u->{week_at} // $week_reset) } } };
    }
    print $json->encode({ type => 'control_response', response => { subtype => 'success', request_id => $msg->{request_id}, response => $answer } }), "\n";
  } elsif ($type eq 'user') {
    for (1 .. 600) { last unless -e '/Users/admin/fill-first/slow'; sleep 1; }
    my $u = usage();
    print $json->encode({ type => 'rate_limit_event', rate_limit_info => { status => 'allowed', unifiedWindows => {
      five_hour => { utilization => $u->{five} / 100, resetsAt => $u->{five_at} // $five_reset },
      seven_day => { utilization => $u->{weekly} / 100, resetsAt => $u->{week_at} // $week_reset } } } }), "\n";
    my $who = $folder =~ /claude-accounts\/(\d+)/ ? "account $1" : 'Account 1';
    print $json->encode({ type => 'assistant', message => { role => 'assistant', content => [ { type => 'text', text => "Answered on $who." } ] } }), "\n";
    print $json->encode({ type => 'result', subtype => 'success', stop_reason => 'end_turn', is_error => JSON::PP::false, result => "Answered on $who." }), "\n";
  }
}
