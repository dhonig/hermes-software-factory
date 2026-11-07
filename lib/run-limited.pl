#!/usr/bin/perl
# Run a command in its own process group with a hard time limit, then make sure
# nothing it started outlives it. macOS ships neither timeout(1) nor setsid(1).
#
#   lib/run-limited.pl <timeout-seconds> <command> [args...]
#
# - timeout 0 means no limit.
# - On timeout the whole group gets TERM, then KILL after RUN_LIMITED_GRACE
#   seconds (default 5), and this exits 124 with "timed out after Ns" on stderr.
# - When the command exits on its own, any process still in its group (a
#   backgrounded server, `trunk serve`, a debug backend) is killed the same way.
# - INT/TERM/HUP to this wrapper are passed to the group, which is then reaped.
# Exit status: the command's, 124 on timeout, 128+n if it died from signal n.
use strict;
use warnings;
use POSIX qw(:sys_wait_h);

my $limit = shift @ARGV;
die "usage: run-limited.pl <timeout-seconds> <command> [args...]\n"
  unless defined $limit && $limit =~ /^\d+$/ && @ARGV;
my $grace = $ENV{RUN_LIMITED_GRACE} // 5;

my $pid = fork() // die "run-limited: fork failed: $!\n";
if ($pid == 0) {
  setpgrp(0, 0) or die "run-limited: setpgrp failed: $!\n";
  no warnings "exec";
  exec { $ARGV[0] } @ARGV or do { print STDERR "run-limited: cannot run $ARGV[0]: $!\n"; POSIX::_exit(127) };
}
# Set it from this side too, so the group exists before any signal arrives.
setpgrp($pid, $pid);

sub group_alive { return kill(0, -$pid) ? 1 : 0 }

sub kill_group {
  return unless group_alive();
  kill 'TERM', -$pid;
  for (1 .. $grace * 10) {
    waitpid($pid, WNOHANG);
    return unless group_alive();
    select(undef, undef, undef, 0.1);
  }
  kill 'KILL', -$pid;
  waitpid($pid, WNOHANG);
}

my ($timed_out, $caught) = (0, '');
# First alarm: TERM the group. If the command ignores it, KILL after the grace.
my $grace_alarm = $grace > 0 ? $grace : 1;
$SIG{ALRM} = sub {
  if ($timed_out || $caught) { kill 'KILL', -$pid; return }
  $timed_out = 1;
  kill 'TERM', -$pid;
  alarm $grace_alarm;
};
for my $sig (qw(INT TERM HUP)) {
  $SIG{$sig} = sub { $caught = $sig; kill $sig, -$pid; alarm $grace_alarm };
}
alarm $limit if $limit > 0;

my $status;
while (1) {
  my $r = waitpid($pid, 0);
  if ($r == $pid) { $status = $?; last }
  next if $r == -1 && $!{EINTR};   # a handler ran; it has signalled the group
  if ($r == -1) { $status = 0; last }   # already reaped
}
alarm 0;
kill_group();

if ($timed_out) {
  print STDERR "run-limited: timed out after ${limit}s: @ARGV\n";
  exit 124;
}
if ($caught) {
  my %num = (INT => 2, HUP => 1, TERM => 15);
  exit 128 + $num{$caught};
}
exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
