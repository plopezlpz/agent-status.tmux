# shellcheck shell=bash
# Optional Paddock formatting. Source this only while preparing a notification.
# No shell command string is evaluated: the configured value is one executable.
# Missing/old/broken formatters keep the caller's original title and message.
paddock_notification() {
  local bin="$1" state="$2" kind="$3" path="$4" icons="$5" out first second
  NOTIFY_TITLE="" NOTIFY_MESSAGE=""
  [ -n "$bin" ] && [ -n "$path" ] || return 1
  case "$icons" in nerd) ;; *) icons=unicode ;; esac
  # Bound BOTH output collection and process completion: a formatter may
  # exit while a descendant holds stdout open. Collect at most 1001 bytes,
  # publish nothing on error, and kill the private process group on all exits.
  # Without Perl's bounded collector, keep the normal standalone message.
  command -v perl >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016 # Perl variables, not shell interpolation.
  out=$(perl -e '
    pipe(my $r, my $w) or exit 127;
    defined(my $p = fork) or exit 127;
    if (!$p) {
      close $r; setpgrp(0, 0) or exit 127;
      open STDOUT, ">&", $w or exit 127; close $w;
      exec @ARGV or exit 127;
    }
    close $w; setpgrp($p, $p);
    my $stop = sub { kill "KILL", -$p; exit $_[0] };
    $SIG{ALRM} = sub { $stop->(124) }; alarm 2;
    $SIG{TERM} = $SIG{HUP} = $SIG{INT} = sub { $stop->(143) };
    my $out = "";
    while (1) {
      my $n = sysread($r, my $buf, 1001 - length($out));
      defined($n) or $stop->(125);
      last unless $n;
      $out .= $buf;
      length($out) <= 1000 or $stop->(125);
    }
    close $r;
    waitpid($p, 0); my $rc = $?;
    kill "KILL", -$p; alarm 0;
    exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8) if $rc;
    print $out;
  ' "$bin" notification "$state" "$kind" "$path" "$icons" </dev/null 2>/dev/null) || return 1
  # Exactly two nonempty, bounded lines. Reject help/errors/partial output.
  case "$out" in *$'\n'*) ;; *) return 1 ;; esac
  first=${out%%$'\n'*}; second=${out#*$'\n'}
  case "$second" in *$'\n'*) return 1 ;; esac
  [ -n "$first" ] && [ -n "$second" ] && [ "${#out}" -le 1000 ] || return 1
  clean_text "$first"; NOTIFY_TITLE=$CLEAN
  clean_text "$second"; NOTIFY_MESSAGE=$CLEAN
  [ -n "$NOTIFY_TITLE" ] && [ -n "$NOTIFY_MESSAGE" ]
}
