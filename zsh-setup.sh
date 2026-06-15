#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# zsh-setup.sh — install / REPAIR zsh + antidote + powerlevel10k
#                for the CURRENT user. No root, no SSH changes.
# ------------------------------------------------------------
#   Repo: https://github.com/Zakkaus/vps
#   Run as your normal (admin) user — NOT root:
#     curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/zsh-setup.sh | bash
#     wget  -qO- https://raw.githubusercontent.com/Zakkaus/vps/main/zsh-setup.sh | bash
#
#   Idempotent: safe to re-run. Use this when the prompt comes up as a bare
#   `localhost%` instead of powerlevel10k (the antidote bundle didn't build).
# ============================================================

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo "Run as your normal user, NOT root (this sets up THIS user's shell)." >&2
  echo "e.g.:  sudo -u <admin-user> -H bash -c 'curl -fsSL .../zsh-setup.sh | bash'" >&2
  exit 1
fi

for c in zsh git; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "ERROR: '$c' is not installed. Install it first (the bootstrap installs both)." >&2
    exit 1
  }
done

ZSH_BIN="$(command -v zsh)"
mkdir -p "$HOME/.cache/zsh" "$HOME/.zsh/plugins"

clone_or_pull() {  # <url> <dest>
  if [[ -d "$2/.git" ]]; then
    echo "  update $2"
    git -C "$2" pull --ff-only --quiet || true
  else
    echo "  clone  $2"
    rm -rf "$2"
    git clone --depth=1 --quiet "$1" "$2"
  fi
}

echo "== zsh-setup: fetching plugins =="
clone_or_pull https://github.com/mattmc3/antidote.git          "$HOME/.antidote"
clone_or_pull https://github.com/zsh-users/zsh-completions.git "$HOME/.zsh/plugins/zsh-completions"

cat > "$HOME/.zsh_plugins.txt" <<'PLUGINS'
romkatv/powerlevel10k
zsh-users/zsh-completions
Aloxaf/fzf-tab
zsh-users/zsh-autosuggestions
zdharma-continuum/fast-syntax-highlighting
zsh-users/zsh-history-substring-search
PLUGINS

echo "== building antidote bundle (downloads plugins, needs network) =="
# antidote is zsh code -> build the static bundle UNDER zsh, not bash.
"$ZSH_BIN" -c '
  source "$HOME/.antidote/antidote.zsh"
  antidote bundle < "$HOME/.zsh_plugins.txt" > "$HOME/.cache/zsh/antidote.zsh"
'

if [[ -s "$HOME/.cache/zsh/antidote.zsh" ]]; then
  echo "✓ bundle built: $(wc -l < "$HOME/.cache/zsh/antidote.zsh") lines -> ~/.cache/zsh/antidote.zsh"
else
  echo "✗ bundle is EMPTY — antidote could not reach github.com. Check network/DNS and re-run." >&2
  exit 1
fi

# make zsh the login shell if it isn't already
if [[ "${SHELL:-}" != "$ZSH_BIN" ]]; then
  if chsh -s "$ZSH_BIN" 2>/dev/null; then
    echo "✓ login shell -> $ZSH_BIN (effective next login)"
  else
    echo "! could not chsh automatically. Run:  chsh -s $ZSH_BIN"
  fi
fi

echo
echo "Done. Activate now:   exec zsh"
echo "Configure the prompt: p10k configure"
