# shellcheck shell=bash
# Shared look and plumbing for the navigator tabs (agent-sessions.sh and
# session-switcher.sh). Source it; don't execute it.
# shellcheck disable=SC2034 # globals and result variables for the sourcing tabs

SEP=$'\037'
TAB=$'\t'
# fzf waits ESCDELAY ms (default 100) after Esc for an escape sequence. tmux
# hands the popup whole sequences already, so a short wait makes Esc close fast.
export ESCDELAY="${ESCDELAY:-10}"

# A tab exits with this code (its query on stdout) to hand over to the next
# tab; navigator.sh loops on it.
NAV_SWITCH_RC=3
NAV_TABS=(agents sessions)

# sgr_of COLOR: tmux colour name or #rrggbb -> SGR foreground parameters.
sgr_of() {
  case "$1" in
    red) SGR=31 ;; green) SGR=32 ;; yellow) SGR=33 ;;
    blue) SGR=34 ;; magenta) SGR=35 ;; cyan) SGR=36 ;; white) SGR=37 ;;
    \#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      SGR="38;2;$((16#${1:1:2}));$((16#${1:3:2}));$((16#${1:5:2}))" ;;
    *) SGR="" ;;
  esac
}

key_hint() { printf '\033[38;2;150;166;200m%s\033[0m \033[2m%s\033[0m   ' "$1" "$2"; }

# utf8_cut N TEXT: the first N characters of TEXT (not bytes, so a multibyte
# character is never split), even when the caller's locale is not UTF-8.
utf8_cut() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) local LC_ALL=C.UTF-8 2>/dev/null ;;
  esac
  CUT=${2:0:$1}
}

clean_text() {
  local text="$1" controls char
  text=${text//$'\n'/ }; text=${text//$'\r'/ }; text=${text//$'\t'/ }
  controls=$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'
  while [ -n "$controls" ]; do
    char=${controls%"${controls#?}"}; controls=${controls#?}; text=${text//"$char"/}
  done
  utf8_cut 240 "$text"; CLEAN="$CUT"
}

# Preview: a header naming what is shown (live output of which pane, which
# agent or command), then the tail of the pane, trailing blank rows dropped.
preview_pane() {
  local pane="$1"
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
  local screen where loc kind cmd cols rule body_lines
  # capture-pane fails for a missing pane (display -p does not).
  screen=$(tmux capture-pane -e -p -t "$pane" 2>/dev/null) || { printf '\033[2mpane is gone\033[0m\n'; return 0; }
  where=$(tmux display -p -t "$pane" $'#{session_name}:#{window_index}.#{pane_index}\037#{@agent-kind}\037#{pane_current_command}' 2>/dev/null || true)
  IFS="$SEP" read -r loc kind cmd <<< "$where"
  clean_text "$loc · ${kind:-$cmd}"; where="$CLEAN"
  cols=${FZF_PREVIEW_COLUMNS:-60}
  printf -v rule '%*s' "$cols" ''
  printf '\033[1;38;2;150;166;200mlive output\033[0m\033[2m  %s\033[0m\n\033[38;2;72;72;72m%s\033[0m\n' \
    "$where" "${rule// /─}"
  body_lines=$(( ${FZF_PREVIEW_LINES:-40} - 2 ))
  [ "$body_lines" -gt 0 ] || return 0
  printf '%s\n' "$screen" | awk '
    { line[NR] = $0; plain = $0; gsub(/\033\[[0-9;:]*[A-Za-z]/, "", plain); gsub(/\033\][^\033]*\033\\/, "", plain)
      if (plain ~ /[^[:space:]]/) last = NR }
    END { for (i = 1; i <= last; i++) print line[i] }' \
    | tail -n "$body_lines"
}

# ----- tabs ---------------------------------------------------------------
# Inside navigator.sh (AGENT_NAV_TABBED=1) each tab is one fzf run: Tab and
# Shift-Tab end it, and the next tab starts from the same query.

# nav_title TAB: the start of the border label. Tabbed, every tab's name with
# TAB highlighted; standalone, just TAB's name.
nav_title() {
  local t out=""
  if [ "${AGENT_NAV_TABBED:-0}" != 1 ]; then printf '\033[1m %s \033[0m' "$1"; return; fi
  for t in "${NAV_TABS[@]}"; do
    if [ "$t" = "$1" ]; then out="$out"$'\033[1;38;2;24;24;24;48;2;225;216;158m'" $t "$'\033[0m'
    else out="$out"$'\033[2m'" $t "$'\033[0m'; fi
  done
  printf '%s' "$out"
}

# nav_tab_hint: the footer's Tab hint, empty standalone.
nav_tab_hint() {
  [ "${AGENT_NAV_TABBED:-0}" != 1 ] || key_hint '⇥' tab
}

# fzf options a tab adds inside navigator.sh.
NAV_TAB_OPTS=()
# shellcheck disable=SC2054 # fzf's key list, not array elements
[ "${AGENT_NAV_TABBED:-0}" != 1 ] || NAV_TAB_OPTS=(--expect=tab,btab --print-query --query="${AGENT_NAV_QUERY:-}")

# nav_result RC OUT: unpack a tab's fzf output into SEL. Tab/Shift-Tab (fzf
# reports the key with exit 0 or, on no match, 1) hands the query to
# navigator.sh and exits.
nav_result() {
  local rc="$1" out="$2" query="" key=""
  SEL="$out"
  [ "${AGENT_NAV_TABBED:-0}" = 1 ] || return 0
  case "$rc" in 0|1) ;; *) SEL=""; return 0 ;; esac
  { IFS= read -r query; IFS= read -r key; SEL=$(cat); } <<< "$out" || true
  case "$key" in
    tab|btab) printf '%s\n' "$query"; exit "$NAV_SWITCH_RC" ;;
  esac
}

# gruber-darker palette, matching the Neovim floats: bg #181818, panel line
# #282828, rule #484848, text #e4e4e4, yellow #e1d89e, green #c0d090,
# niagara #96a6c8. One rounded frame with label, input line and footer.
# shellcheck disable=SC2016 # fzf expands these, not bash
NAV_FZF_STYLE=(
  --with-shell='/bin/sh -c' --ansi --reverse --no-sort --cycle
  --border=rounded --border-label-pos=3 --input-border=line --footer-border=line
  --info=inline-right --info-command='printf %s "${FZF_INFO%% +*}"' --prompt='› '
  --pointer='▌' --highlight-line
  --preview-window='right,50%,border-left,<70(up,50%,border-bottom,hidden)'
  --color='bg:#181818,fg:#e4e4e4,bg+:#282828,fg+:#f5f5f5:regular,gutter:#181818'
  --color='hl:#c0d090:bold,hl+:#c0d090:bold,pointer:#e1d89e,marker:#96a6c8,spinner:#e1d89e'
  --color='prompt:#e1d89e,query:#f5f5f5,ghost:#a0a0a0,info:#565f73,label:#e4e4e4,nomatch:dim'
  --color='border:#484848,separator:#282828,input-border:#282828,footer-border:#282828'
  --color='preview-border:#282828,preview-label:#a0a0a0,scrollbar:#484848,preview-scrollbar:#484848'
  --bind 'ctrl-/:toggle-preview'
)

# nav_compact: COMPACT=1 in a popup under 80 columns (a phone).
nav_compact() {
  local cols
  read -r _ cols < <(stty size 2>/dev/null < /dev/tty || echo '24 80')
  COMPACT=0; [ "$cols" -ge 80 ] || COMPACT=1
}
