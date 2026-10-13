#!/usr/bin/env bash
# Session navigator: every session and its windows as a tree, with the worst
# agent state per window. The navigator's sessions tab (navigator.sh).
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/nav-lib.sh
. "$SCRIPT_DIR/nav-lib.sh"

case "${1:-}" in
  --preview) preview_pane "${2:-}"; exit 0 ;;
esac

# The popup supplies its invoking client and location. Never guess a client:
# another terminal may become active while this picker is open.
CLIENT=${AGENT_NAV_CLIENT:?launch the session navigator from its tmux key}
CUR_SID=${AGENT_NAV_SESSION:?missing popup session}
CUR_WID=${AGENT_NAV_WINDOW:?missing popup window}

# Agent rank, same priority as update-window-icon.sh: asking > working >
# finished (idle + unseen) > idle.
rank_of() {
  case "$1:$2" in
    asking:*) RANK=4 ;; working:*) RANK=3 ;; idle:1) RANK=2 ;; idle:*) RANK=1 ;; *) RANK=0 ;;
  esac
}

# Agent glyphs and colours in the invoking client's window, in one call.
IFS="$SEP" read -r icon_1 icon_2 icon_3 icon_4 color_1 color_2 color_3 color_4 < <(
  tmux display -p -c "$CLIENT" -t "$CUR_SID:$CUR_WID" $'#{@agent-icon-idle}\037#{@agent-icon-finished}\037#{@agent-icon-working}\037#{@agent-icon-asking}\037#{@agent-color-idle}\037#{@agent-color-finished}\037#{@agent-color-working}\037#{@agent-color-asking}' 2>/dev/null) || true
# Indexed by agent rank (see rank_of); 0 = no agent.
ICON=('' "${icon_1:-○}" "${icon_2:-●}" "${icon_3:-●}" "${icon_4:-●}")
COLOR=('' "${color_1:-green}" "${color_2:-cyan}" "${color_3:-yellow}" "${color_4:-red}")
LABEL=('' idle finished working waiting)
COUNT=(0 0 0 0 0)
DOT=(' ')
for r in 1 2 3 4; do
  sgr_of "${COLOR[r]}"
  dot="${ICON[r]}"
  [ -z "$SGR" ] || printf -v dot '\033[%sm%s\033[0m' "$SGR" "$dot"
  DOT[r]="$dot"
done

# One snapshot of every pane, rolled up per window (keyed by session too, since
# a linked window is listed once per session) and grouped per session.
nw=0 ns=0 key="" sess_key=""
while IFS="$SEP" read -r sid sname attached wid widx wname wactive pid pactive state unseen path; do
  [[ "$pid" =~ ^%[0-9]+$ ]] || continue
  if [ "$sid" != "$sess_key" ]; then
    sess_key="$sid"
    S_ID[ns]="$sid"; S_NAME[ns]="$sname"; S_ATT[ns]="$attached"; S_FIRST[ns]="$nw"; S_PANE[ns]="$pid"
    ns=$((ns + 1))
  fi
  if [ "$sid:$wid" != "$key" ]; then
    key="$sid:$wid"
    W_SID[nw]="$sid"; W_SESS[nw]="$sname"; W_ID[nw]="$wid"; W_IDX[nw]="$widx"; W_NAME[nw]="$wname"
    W_ACTIVE[nw]="$wactive"; W_PANES[nw]=0; W_RANK[nw]=0; W_PANE[nw]="$pid"; W_PATH[nw]="$path"
    nw=$((nw + 1))
  fi
  w=$((nw - 1))
  W_PANES[w]=$((W_PANES[w] + 1))
  if [ "$pactive" = 1 ]; then
    W_PANE[w]="$pid"; W_PATH[w]="$path"
    [ "$wactive" != 1 ] || S_PANE[ns - 1]="$pid"
  fi
  rank_of "$state" "$unseen"
  [ "$RANK" -le "${W_RANK[w]}" ] || W_RANK[w]=$RANK
  COUNT[RANK]=$((COUNT[RANK] + 1))
done < <(tmux list-panes -a -F $'#{session_id}\037#{session_name}\037#{session_attached}\037#{window_id}\037#{window_index}\037#{window_name}\037#{window_active}\037#{pane_id}\037#{pane_active}\037#{@agent-state}\037#{@agent-unseen}\037#{pane_current_path}' 2>/dev/null)
[ "$nw" -gt 0 ] || exit 0
S_FIRST[ns]="$nw"

# A popup under 80 columns (a phone) gets compact rows, label and padding.
nav_compact

# Column widths: index right-aligned, names padded (capped) so folders line up.
idx_w=1 name_w=4
for ((i = 0; i < nw; i++)); do
  [ "${#W_IDX[i]}" -le "$idx_w" ] || idx_w=${#W_IDX[i]}
  [ "${#W_NAME[i]}" -le "$name_w" ] || name_w=${#W_NAME[i]}
done
[ "$name_w" -le 24 ] || name_w=24

# short_path PATH: ~-relative, and only the last two folders when long
# (compact: only the last folder past 16 characters).
short_path() {
  local p="$1" tail
  p=${p//$'\t'/ }; p=${p//$'\033'/}; p=${p//$SEP/}
  case "$p" in "$HOME") p='~' ;; "$HOME"/*) p="~${p#"$HOME"}" ;; esac
  if [ "$COMPACT" = 1 ] && [ "${#p}" -gt 16 ]; then
    [ "${p##*/}" = "$p" ] || p="…/${p##*/}"
  elif [ "${#p}" -gt 32 ]; then
    tail="${p%/*}"; tail="${tail##*/}/${p##*/}"
    [ "$tail" = "$p" ] || p="…/$tail"
  fi
  SHORT="$p"
}

# Rows: kind \037 session id \037 window id \037 preview pane \037 display.
# Only the display is shown and searched; the ids drive switching.
C_RULE=$'\033[38;2;72;72;72m' C_IDX=$'\033[38;2;86;95;115m' C_ACTIVE=$'\033[38;2;225;216;158m'
C_BADGE=$'\033[1;38;2;32;32;32;48;2;162;169;112m' C_DIM=$'\033[2m' C_BOLD=$'\033[1m' C_OFF=$'\033[0m'
list="" row=0 cur_row=1
for ((s = 0; s < ns; s++)); do
  first=${S_FIRST[s]} next=${S_FIRST[s + 1]} wins=$((S_FIRST[s + 1] - S_FIRST[s]))
  if [ "${S_ID[s]}" = "$CUR_SID" ]; then
    title="$C_BADGE ${S_NAME[s]} $C_OFF"
  else
    title=" $C_BOLD${S_NAME[s]}$C_OFF "
  fi
  meta="$wins windows"; [ "$wins" -ne 1 ] || meta="1 window"
  [ "${S_ATT[s]}" = 0 ] || [ "${S_ID[s]}" = "$CUR_SID" ] || meta="$meta · attached"
  row=$((row + 1))
  printf -v line 'S\037%s\037-\037%s\037%s %s%s%s\n' \
    "${S_ID[s]}" "${S_PANE[s]}" "$title" "$C_DIM" "$meta" "$C_OFF"
  list="$list$line"
  for ((w = first; w < next; w++)); do
    branch="├─"; [ "$w" -ne $((next - 1)) ] || branch="└─"
    idx_c="$C_IDX" name="${W_NAME[w]}" name_c=""
    if [ "${W_ACTIVE[w]}" = 1 ]; then idx_c="$C_ACTIVE" name_c="$C_BOLD"; fi
    pad=$((name_w - ${#name})); [ "$pad" -gt 0 ] || pad=0
    # fzf searches only displayed fields: include the session on window rows
    # (compact rows drop it for room; its header row still matches).
    short_path "${W_PATH[w]}"; meta="${W_SESS[w]} · $SHORT"
    [ "$COMPACT" = 0 ] || meta="$SHORT"
    [ "${W_PANES[w]}" -le 1 ] || meta="$meta · ${W_PANES[w]} panes"
    row=$((row + 1))
    [ "${W_SID[w]}" != "$CUR_SID" ] || [ "${W_ID[w]}" != "$CUR_WID" ] || cur_row=$row
    printf -v line 'W\037%s\037%s\037%s\037 %s%s%s %s%*s%s %s %s%s%s%*s  %s%s%s\n' \
      "${W_SID[w]}" "${W_ID[w]}" "${W_PANE[w]}" \
      "$C_RULE" "$branch" "$C_OFF" "$idx_c" "$idx_w" "${W_IDX[w]}" "$C_OFF" "${DOT[W_RANK[w]]}" \
      "$name_c" "$name" "$C_OFF" "$pad" "" "$C_DIM" "$meta" "$C_OFF"
    list="$list$line"
  done
done

# Border label: title, totals and a count per agent state, attention first.
label="$(nav_title sessions)$C_DIM $ns · $nw windows $C_OFF"
for r in 4 3 2 1; do
  [ "${COUNT[r]}" -gt 0 ] || continue
  # Compact: the coloured glyph alone, so the label fits a phone's border.
  if [ "$COMPACT" = 1 ]; then label="$label ${DOT[r]} ${COUNT[r]} "; else label="$label ${DOT[r]} ${COUNT[r]} ${LABEL[r]} "; fi
done

printf -v self_q '%q' "$0"
footer="$(key_hint '⏎' switch)$(nav_tab_hint)$(key_hint '^/' preview)$(key_hint esc close)"
padding=0,1 ghost='filter by session, window or folder'
[ "$COMPACT" = 0 ] || { padding=0 ghost='filter sessions'; }
# --raw keeps the tree visible while filtering: non-matches are dimmed and the
# cursor only visits matches. An empty query parks it on the current window.
rc=0
out=$(printf '%s' "$list" | fzf "${NAV_FZF_STYLE[@]}" ${NAV_TAB_OPTS[@]+"${NAV_TAB_OPTS[@]}"} \
  --raw --delimiter="$SEP" --with-nth=5.. \
  --border-label="$label" --padding="$padding" --footer="${footer%   }" --ghost="$ghost" \
  --preview="$self_q --preview {4}" \
  --bind 'ctrl-n,ctrl-j,down:down-match' --bind 'ctrl-p,ctrl-k,up:up-match' \
  --bind "result:transform:[ -n \"\$FZF_QUERY\" ] && echo best || echo 'pos($cur_row)'" \
  --bind 'enter:transform:[ "${FZF_RAW:-1}" = 0 ] || echo accept') || rc=$?
nav_result "$rc" "$out"; sel="$SEL"
# 1 = no match, 130 = cancelled; anything else is an fzf error worth seeing.
case "$rc" in
  0) ;; 1|130) exit 0 ;;
  *) tmux display-message -c "$CLIENT" "session navigator: fzf exited $rc"; exit 0 ;;
esac

[ -n "$sel" ] || exit 0
IFS="$SEP" read -r kind sid wid _ <<< "$sel"
# Resolve both the client and destination in one command, so a stale target
# cannot partially switch sessions. Keep linked windows scoped to the session
# selected in the list, and preserve the destination window's zoom state.
case "$kind" in
  S) tmux switch-client -c "$CLIENT" -t "$sid" 2>/dev/null ;;
  W) tmux switch-client -Z -c "$CLIENT" -t "$sid:$wid" 2>/dev/null ;;
esac || tmux display-message -c "$CLIENT" "session navigator: that client, session or window is gone"
