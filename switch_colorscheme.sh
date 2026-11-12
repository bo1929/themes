#!/bin/bash
# Switch the terminal colorscheme across components.
#
# Canonical state: the import line in STATE_FILE (~/.config/theme/).
# Everything else (alacritty, tmux, vim at launch, zsh) derives from it.
#
# Components (each optional):
#   alacritty  rewrite the colorscheme import in STATE_FILE (canonical
#              state for vim/zsh/ssh) and copy the theme's palette to
#              ACTIVE_FILE, the fixed path alacritty.toml imports. The
#              fixed import path keeps alacritty's config watcher stable:
#              alacritty restarts its watcher whenever the set of imported
#              paths changes, and a restarted watcher can miss later
#              writes (observed on 0.13.x/macOS).
#   tmux       write the per-theme status color to TMUX_STATE and apply it
#              to a running server; tmux.conf sources TMUX_STATE at start
#              and runs "switch_colorscheme.sh sync" to converge.
#              Themes missing from the map below reset the status line to
#              the default fg instead of keeping a stale color.
#
# State files are written in place (truncate + single write): alacritty's
# config watcher reacts to data modifications on the watched file, and a
# rename replacement (temp file + mv) can leave it stale on macOS. The
# content is a single small write, so the truncation window is negligible.
#
# Configuration, lowest to highest precedence:
#   1. defaults below
#   2. config file (~/.config/theme/switch_colorscheme.conf, shell syntax)
#   3. environment variables of the same names
#   4. CLI flags (--no-alacritty, --no-tmux)
#
#   SWITCH_ALACRITTY   1|0   alacritty component on/off   (default 1)
#   SWITCH_TMUX        1|0   tmux component on/off        (default 1)
#   THEME_DIR          path  theme files                  (default ~/.config/theme/themes)
#   STATE_FILE         path  file carrying the import     (default ~/.config/theme/colorschemes.toml)
#   ACTIVE_FILE        path  live palette alacritty imports (default ~/.config/theme/active.toml)
#   TMUX_STATE         path  persisted tmux status color  (default ~/.config/tmux/current-theme.conf)
#   SWITCH_CONFIG_FILE path  use a different config file
#
# Usage:
#   switch_colorscheme.sh [--no-alacritty] [--no-tmux] <theme-name>
#   switch_colorscheme.sh sync   re-apply the canonical theme (from the
#                                import in STATE_FILE) to all components
#
# To support another theme, add its palette to THEME_DIR and its tmux
# foreground color to the mapping case below. To support another terminal,
# replace the alacritty component with its config-writing mechanism.
set -u
set -o pipefail

# Remember env overrides before sourcing the config file: the environment
# must keep precedence over the config file (see precedence list above).
_e_alacritty="${SWITCH_ALACRITTY-}"; _h_alacritty="${SWITCH_ALACRITTY+set}"
_e_tmux="${SWITCH_TMUX-}";           _h_tmux="${SWITCH_TMUX+set}"
_e_theme_dir="${THEME_DIR-}";        _h_theme_dir="${THEME_DIR+set}"
_e_state_file="${STATE_FILE-}";      _h_state_file="${STATE_FILE+set}"
_e_active_file="${ACTIVE_FILE-}";    _h_active_file="${ACTIVE_FILE+set}"
_e_alacritty_toml="${ALACRITTY_TOML-}"; _h_alacritty_toml="${ALACRITTY_TOML+set}"
_e_tmux_state="${TMUX_STATE-}";      _h_tmux_state="${TMUX_STATE+set}"
unset SWITCH_ALACRITTY SWITCH_TMUX THEME_DIR STATE_FILE ACTIVE_FILE ALACRITTY_TOML TMUX_STATE

# --- 2. config file ---
CONFIG_FILE="${SWITCH_CONFIG_FILE:-$HOME/.config/theme/switch_colorscheme.conf}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# --- 1. defaults (values set by the config file are kept) ---
SWITCH_ALACRITTY="${SWITCH_ALACRITTY:-1}"
SWITCH_TMUX="${SWITCH_TMUX:-1}"
THEME_DIR="${THEME_DIR:-$HOME/.config/theme/themes}"
STATE_FILE="${STATE_FILE:-$HOME/.config/theme/colorschemes.toml}"
ACTIVE_FILE="${ACTIVE_FILE:-$HOME/.config/theme/active.toml}"
ALACRITTY_TOML="${ALACRITTY_TOML:-$HOME/.config/alacritty/alacritty.toml}"
TMUX_STATE="${TMUX_STATE:-$HOME/.config/tmux/current-theme.conf}"

# --- 3. environment wins over the config file ---
[ -n "$_h_alacritty" ]  && SWITCH_ALACRITTY="$_e_alacritty"
[ -n "$_h_tmux" ]       && SWITCH_TMUX="$_e_tmux"
[ -n "$_h_theme_dir" ]  && THEME_DIR="$_e_theme_dir"
[ -n "$_h_state_file" ] && STATE_FILE="$_e_state_file"
[ -n "$_h_active_file" ] && ACTIVE_FILE="$_e_active_file"
[ -n "$_h_alacritty_toml" ] && ALACRITTY_TOML="$_e_alacritty_toml"
[ -n "$_h_tmux_state" ] && TMUX_STATE="$_e_tmux_state"

usage() {
  echo "Usage: switch_colorscheme.sh [--no-alacritty] [--no-tmux] <theme-name>" >&2
  echo "       switch_colorscheme.sh sync" >&2
  if [ -d "$THEME_DIR" ]; then
    echo "Available themes:" >&2
    (cd "$THEME_DIR" && ls) | sed 's/\.toml$//' >&2
  else
    echo "Theme directory not found: $THEME_DIR" >&2
  fi
}

# write_state <dest>: read stdin and write it in place to <dest>
# (truncate + single write; preserves inode, mode, and watcher state —
# see the note on write mode in the header).
write_state() {
  local dest="$1" dir
  dir=$(dirname "$dest")
  mkdir -p "$dir" || { echo "error: cannot create $dir" >&2; return 1; }
  cat > "$dest" || { echo "error: cannot write $dest" >&2; return 1; }
}

# --- 4. CLI flags ---
theme=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-alacritty) SWITCH_ALACRITTY=0 ;;
    --no-tmux)      SWITCH_TMUX=0 ;;
    -h|--help)      usage; exit 0 ;;
    --*)            echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *)
      if [ -n "$theme" ]; then
        echo "unexpected extra argument: $1" >&2; usage; exit 2
      fi
      theme="$1" ;;
  esac
  shift
done

if [ -z "$theme" ]; then
  echo "error: no theme given" >&2
  usage
  exit 2
fi

# sync: adopt the canonical theme recorded in STATE_FILE's import line
# (last import wins, matching alacritty).
if [ "$theme" = "sync" ]; then
  theme=$(grep -o '[^"/]*\.toml' "$STATE_FILE" 2>/dev/null | tail -1 | sed 's/\.toml$//')
  if [ -z "$theme" ]; then
    echo "sync: no theme import found in $STATE_FILE" >&2
    exit 1
  fi
fi

if [ ! -f "$THEME_DIR/$theme.toml" ]; then
  echo "unknown theme: '$theme'" >&2
  usage
  exit 1
fi

status=0

# --- component: alacritty ---
if [ "$SWITCH_ALACRITTY" = "1" ]; then
  case "$THEME_DIR" in
    "$HOME"/*) theme_import="~/${THEME_DIR#"$HOME"/}/$theme.toml" ;;
    *)         theme_import="$THEME_DIR/$theme.toml" ;;
  esac
  if ! printf '# Active colorscheme. Change via switch_colorscheme.sh <theme-name>.\nimport = ["%s"]\n' \
      "$theme_import" | write_state "$STATE_FILE"; then
    echo "error: could not update $STATE_FILE" >&2
    status=1
  fi
  # Live palette for alacritty: a verbatim copy of the theme file at the
  # fixed path alacritty.toml imports (see the component note above).
  if ! cat "$THEME_DIR/$theme.toml" | write_state "$ACTIVE_FILE"; then
    echo "error: could not update $ACTIVE_FILE" >&2
    status=1
  fi
  # Deterministic reload trigger: rewrite the PRIMARY config in place with
  # identical content. Alacritty's watcher always watches the primary
  # config file, and its reload re-reads imports from disk — so this works
  # even when events on imported files are missed.
  if [ -f "$ALACRITTY_TOML" ]; then
    poke_tmp=$(mktemp "${TMPDIR:-/tmp}/alacritty_poke.XXXXXX") || poke_tmp=""
    if [ -n "$poke_tmp" ] && cat "$ALACRITTY_TOML" > "$poke_tmp"; then
      cat "$poke_tmp" > "$ALACRITTY_TOML" \
        || echo "warning: could not poke $ALACRITTY_TOML" >&2
    fi
    [ -n "$poke_tmp" ] && rm -f "$poke_tmp"
  fi
fi

# --- component: tmux ---
if [ "$SWITCH_TMUX" = "1" ]; then
  # theme -> status bar foreground; empty means "reset to default fg".
  case "$theme" in
    gruvbox_dark_hard)       tmux_fg="#fbf1c7" ;;
    gruvbox_light_hard)      tmux_fg="#282828" ;;
    gruvbox_dark_medium)     tmux_fg="#fbf1c7" ;;
    gruvbox_light_medium)    tmux_fg="#282828" ;;
    everforest_dark_soft)    tmux_fg="#d3c6aa" ;;
    everforest_light_soft)   tmux_fg="#465158" ;;
    everforest_dark_medium)  tmux_fg="#d3c6aa" ;;
    everforest_light_medium) tmux_fg="#465158" ;;
    everforest_dark_hard)    tmux_fg="#d3c6aa" ;;
    everforest_light_hard)   tmux_fg="#465158" ;;
    ayu_mirage)              tmux_fg="#cbccc6" ;;
    ayu_dark)                tmux_fg="#b3b1ad" ;;
    ayu_light)               tmux_fg="#5c6166" ;;
    solarized_light)         tmux_fg="#586e75" ;;
    solarized_dark)          tmux_fg="#839496" ;;
    *)                       tmux_fg="" ;;
  esac
  if [ -n "$tmux_fg" ]; then
    tmux_style="bg=default,fg=$tmux_fg"
  else
    tmux_style="bg=default"
  fi
  if printf "set -g status-style '%s'\n" "$tmux_style" | write_state "$TMUX_STATE"; then
    if command -v tmux >/dev/null && tmux has-session 2>/dev/null; then
      tmux source-file "$TMUX_STATE" \
        || echo "warning: tmux source-file $TMUX_STATE failed" >&2
    fi
  else
    echo "warning: could not update $TMUX_STATE" >&2
    status=1
  fi
fi

exit $status
