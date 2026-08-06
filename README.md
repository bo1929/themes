# ~/.config/theme — terminal theme system

One canonical state file drives the colorscheme across alacritty, tmux,
vim, and zsh. This directory is intentionally terminal-agnostic: only the
"alacritty component" in the switch script is alacritty-specific.

## Layout

    ~/.config/theme/
    ├── colorschemes.toml       canonical state: a single `import` line
    ├── switch_colorscheme.sh   the only writer of that state
    ├── switch_colorscheme.conf optional per-user overrides (shell syntax)
    └── themes/                 one <theme-name>.toml per palette

`colorschemes.toml` always looks like:

    import = ["~/.config/theme/themes/gruvbox_dark.toml"]

Everything derives the active theme from that line — the basename of the
imported file, minus `.toml`.

## Conventions

- **Theme name = file name** in `themes/`, e.g. `nord.toml` → theme `nord`.
- **Dark/light pairing**: name paired variants `<name>_dark` / `<name>_light`.
  Consumers rely on this:
  - `theme toggle` (zsh) flips `_dark` ↔ `_light`; themes without the
    suffix (nord, night-owl, ayu_mirage) cannot be toggled.
  - vim and zsh treat any name containing `light` as a light theme when
    picking fallback colors. Keep `light` in the names of light themes.
- **New theme checklist**:
  1. Add `themes/<name>.toml` (alacritty `[colors.*]` format).
  2. Add its tmux status foreground (usually the palette's primary
     foreground) to the `case` mapping in `switch_colorscheme.sh`.
     Without it tmux is simply left unchanged.
  3. If you want vim to follow it with a matching vim colorscheme,
     install the scheme and extend `theme_map` in
     `~/.vim/misc.vim` (`SwitchTerminalTheme`) and the prefix check in
     `SyncColorschemeWithTerminal`. Otherwise vim falls back gracefully
     (see below).

## How components consume the state

| component | reads state | reacts live | how |
|-----------|-------------|-------------|-----|
| alacritty  | yes (imports `colorschemes.toml`) | yes | live config reload when the script rewrites the import |
| tmux       | via `~/.config/tmux/current-theme.conf` | yes | script writes + sources it; tmux.conf sources it at start and runs `switch_colorscheme.sh sync` |
| vim        | yes, at launch (`SyncColorschemeWithTerminal`) | only via `<leader>BG` | toggle pushes back through the script (async) |
| zsh        | yes, at shell start + `theme` command | via `theme` | parses state for the autosuggestion dim color |

The local machine is the single writer. `switch_colorscheme.sh sync`
re-applies the canonical state everywhere (drift healer; tmux runs it at
server start).

## Switching

    theme                 # zsh: show current + available
    theme <name>          # switch everything
    theme toggle          # flip _dark <-> _light
    switch_colorscheme.sh [--no-alacritty] [--no-tmux] <name|sync>

In vim: `<leader>BG` toggles dark/light and pushes the change to the
terminal (async, non-blocking).

## Fallbacks and failure behavior

- **alacritty**: missing import target → logs a warning, uses default colors.
- **script**: missing state file on `sync` → clean error, exit 1.
  Unknown theme → lists available, exit 1.
- **vim**: no hint → `gruvbox` + `background=dark`. Foreign theme (no
  matching vim colorscheme) → gruvbox with `background` from the name's
  light suffix (unknown suffix assumed dark). Missing colorscheme plugin
  → `darkblue`.
- **tmux**: missing `current-theme.conf` → transparent bar with default
  terminal fg. Unknown theme → left untouched.
- **zsh**: unparsable state → dark dim suggestion color. `theme` with no
  state → prints `current: <none>`; `toggle` errors with a message;
  `theme <name>` recreates the state file (recovery path).

## Remote (SSH)

The state file is local; SSH cannot see it. Instead the local `ssh`
wrapper (`~/.config/zsh/functions/ssh`) exports `LC_THEME=<theme>`,
which sshd's default `AcceptEnv LANG LC_*` lets through:

- remote vim: `LC_THEME` is the highest-priority theme hint
  (`SyncColorschemeWithTerminal`), then the state file, then fallback.
- remote zsh: `LC_THEME` drives the autosuggestion dim color.

The hint is a snapshot at connection time; toggling the local theme does
not reach already-open remote sessions. If sshd refuses `LC_*`, remote
degrades to the plain fallback (gruvbox dark; `<leader>BG` fixes per
session).

## Adapting to another terminal

Only the "component: alacritty" block in `switch_colorscheme.sh` is
terminal-specific. Replace it with the new terminal's config-writing
mechanism and keep `colorschemes.toml` as the state file — tmux, vim,
and zsh need no changes.
