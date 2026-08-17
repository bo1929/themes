#!/bin/bash
# Switch the terminal colorscheme across components.
#
# Canonical state: the import line in STATE_FILE (~/.config/theme/).
# Everything else (alacritty, tmux, vim at launch, zsh) derives from it.
#
# Components (each optional):
#   alacritty  rewrite the colorscheme import; live-reloads running windows
#   tmux       write the per-theme status color to TMUX_STATE and apply it
#              to a running server; tmux.conf sources TMUX_STATE at start
#              and runs "switch_colorscheme.sh sync" to converge
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

# --- 2. config file ---
CONFIG_FILE="${SWITCH_CONFIG_FILE:-$HOME/.config/theme/switch_colorscheme.conf}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# --- 1./3. defaults, overridable by config file or environment ---
SWITCH_ALACRITTY="${SWITCH_ALACRITTY:-1}"
SWITCH_TMUX="${SWITCH_TMUX:-1}"
THEME_DIR="${THEME_DIR:-$HOME/.config/theme/themes}"
STATE_FILE="${STATE_FILE:-$HOME/.config/theme/colorschemes.toml}"
TMUX_STATE="${TMUX_STATE:-$HOME/.config/tmux/current-theme.conf}"

# --- 4. CLI flags ---
theme=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-alacritty) SWITCH_ALACRITTY=0 ;;
    --no-tmux)      SWITCH_TMUX=0 ;;
    --*)            echo "unknown flag: $1" >&2; exit 2 ;;
    *)              theme="$1" ;;
  esac
  shift
done

# sync: adopt the canonical theme recorded in STATE_FILE's import line.
if [ "$theme" = "sync" ]; then
  theme=$(grep -o '[^"/]*\.toml' "$STATE_FILE" 2>/dev/null | tail -1 | sed 's/\.toml$//')
  if [ -z "$theme" ]; then
    echo "sync: no theme import found in $STATE_FILE" >&2
    exit 1
  fi
fi

if [ ! -f "$THEME_DIR/$theme.toml" ]; then
  echo "unknown theme: '$theme'. Available:" >&2
  ls "$THEME_DIR" | sed 's/\.toml$//' >&2
  exit 1
fi

# --- component: alacritty ---
if [ "$SWITCH_ALACRITTY" = "1" ]; then
  case "$THEME_DIR" in
    "$HOME"/*) theme_import="~/${THEME_DIR#"$HOME"/}/$theme.toml" ;;
    *)         theme_import="$THEME_DIR/$theme.toml" ;;
  esac
  printf '# Active colorscheme. Change via switch_colorscheme.sh <theme-name>.\nimport = ["%s"]\n' \
    "$theme_import" > "$STATE_FILE"
fi

# --- component: tmux ---
if [ "$SWITCH_TMUX" = "1" ]; then
  # theme -> status bar foreground; empty means "leave tmux alone".
  case "$theme" in
    gruvbox_dark)            tmux_fg="#ebdbb2" ;;
    gruvbox_light)           tmux_fg="#3c3836" ;;
    gruvbox_dark_medium)     tmux_fg="#ebdbb2" ;;
    gruvbox_light_medium)    tmux_fg="#3c3836" ;;
    gruvbox_material)        tmux_fg="#dfbf8e" ;;
    everforest_dark_soft)    tmux_fg="#d3c6aa" ;;
    everforest_light_soft)   tmux_fg="#465158" ;;
    everforest_dark_medium)  tmux_fg="#d3c6aa" ;;
    everforest_light_medium) tmux_fg="#465158" ;;
    everforest_dark_hard)    tmux_fg="#d3c6aa" ;;
    everforest_light_hard)   tmux_fg="#465158" ;;
    ayu_mirage)              tmux_fg="#cbccc6" ;;
    ayu_dark)                tmux_fg="#b3b1ad" ;;
    base16_dark)             tmux_fg="#d8d8d8" ;;
    night-owl)               tmux_fg="#d6deeb" ;;
    nord)                    tmux_fg="#d8dee9" ;;
    solarized_light)         tmux_fg="#586e75" ;;
    tomorrow_night)          tmux_fg="#c5c8c6" ;;
    *)                       tmux_fg="" ;;
  esac
  if [ -n "$tmux_fg" ]; then
    printf "set -g status-style 'bg=default,fg=%s'\n" "$tmux_fg" > "$TMUX_STATE"
    if command -v tmux >/dev/null && tmux has-session 2>/dev/null; then
      tmux source-file "$TMUX_STATE"
    fi
  fi
fi
