#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VPS bootstrap — admin user + SSH hardening + zsh/tmux
# ------------------------------------------------------------
#   Repo:  https://github.com/Zakkaus/vps
#   Usage: curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh | sudo bash
#
#   Optional overrides (export, or prefix with `sudo VAR=... bash`):
#     SSH_PORT        SSH listen port              (default: 61000)
#     ADMIN_USER      admin account name           (default: admin<random>)
#     ADMIN_PASS      admin password               (default: random)
#     SRC_AUTH_KEYS   path to authorized_keys      (default: invoking user's)
#
# Supports: Debian/Ubuntu (systemd), openSUSE/SLES (systemd),
#           Gentoo (OpenRC or systemd)
# ============================================================

SSH_PORT="${SSH_PORT:-61000}"
# Defaults for user/pass are generated AFTER package install (we may need a RNG).
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"

# --- FIX: resolve the *invoking* user's authorized_keys, not root's. ---
# When run via `sudo`, $HOME may be /root with no keys -> would lock you out.
if [[ -n "${SRC_AUTH_KEYS:-}" ]]; then
  :  # explicit override, keep as given
elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  _inv_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
  SRC_AUTH_KEYS="${_inv_home:-$HOME}/.ssh/authorized_keys"
else
  SRC_AUTH_KEYS="$HOME/.ssh/authorized_keys"
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (or via sudo)." >&2
  exit 1
fi

# --- SAFETY: refuse to run at all without a usable SSH public key. ---
# This check runs FIRST — before installing packages, creating users, or
# touching any config — so an abort here leaves the system 100% unchanged.
valid_authkeys() {  # <file>  -> 0 if it holds at least one usable public key
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 1
  # Authoritative check if available: ssh-keygen lists fingerprints of valid keys.
  if command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -l -f "$f" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback: match a real key-type token (allows an options prefix), then a blob.
  grep -Eq '(^|[[:space:]])(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/]' "$f"
}

if ! valid_authkeys "$SRC_AUTH_KEYS"; then
  echo "ERROR: no usable SSH public key found at: $SRC_AUTH_KEYS" >&2
  echo "This script disables password SSH login, so it will NOT run without a key" >&2
  echo "(continuing could lock you out). NOTHING has been changed on this system." >&2
  echo >&2
  echo "Fix one of:" >&2
  echo "  - add your public key, e.g.:" >&2
  echo "      install -d -m700 ~/.ssh && curl -fsSL https://github.com/<you>.keys >> ~/.ssh/authorized_keys" >&2
  echo "  - or point the script at an existing keys file:" >&2
  echo "      curl -fsSL .../vps-bootstrap.sh | sudo SRC_AUTH_KEYS=/path/to/authorized_keys bash" >&2
  exit 1
fi

source /etc/os-release 2>/dev/null || true
OS_ID="${ID:-unknown}"

# --- FIX: detect the *active* init system instead of assuming systemd. ---
# Gentoo defaults to OpenRC; systemctl simply does not exist there.
detect_init() {
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo systemd
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    echo openrc
  elif command -v service >/dev/null 2>&1; then
    echo sysv
  else
    echo unknown
  fi
}
INIT_SYS="$(detect_init)"

# --- FIX: RNG that does not require openssl (openssl is installed later). ---
gen_hex() {  # gen_hex <num_bytes>
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}
gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24
  else
    head -c 24 /dev/urandom | base64 | tr -d '\n'
  fi
}

install_pkgs() {
  case "$OS_ID" in
    debian|ubuntu)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        sudo git curl wget zsh tmux vim openssl ca-certificates fzf
      SSH_SERVICE="ssh"
      SUDO_GROUP="sudo"
      ;;
    opensuse*|sles|sled)
      zypper --non-interactive refresh
      zypper --non-interactive install \
        sudo git curl wget zsh tmux vim openssl ca-certificates fzf
      SSH_SERVICE="sshd"
      SUDO_GROUP="wheel"
      ;;
    gentoo)
      # FIX: drop `-a` (interactive ask) so it does not block automation.
      emerge --sync || true
      emerge --noreplace --quiet \
        app-admin/sudo dev-vcs/git net-misc/curl net-misc/wget app-shells/zsh \
        app-misc/tmux app-editors/vim dev-libs/openssl app-shells/fzf
      SSH_SERVICE="sshd"
      SUDO_GROUP="wheel"
      ;;
    *)
      echo "Unsupported OS: $OS_ID" >&2
      exit 1
      ;;
  esac
}

install_pkgs

# Now that a RNG exists, fill in any unset defaults.
[[ -z "$ADMIN_USER" ]] && ADMIN_USER="admin$(gen_hex 3)"
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(gen_pass)"

echo "== VPS bootstrap =="
echo "Admin user: $ADMIN_USER"
echo "SSH port:   $SSH_PORT"
echo "Init:       $INIT_SYS"

# sudo group
getent group "$SUDO_GROUP" >/dev/null || groupadd "$SUDO_GROUP"

# create admin
ZSH_BIN="$(command -v zsh || true)"
: "${ZSH_BIN:=/bin/zsh}"
if id "$ADMIN_USER" >/dev/null 2>&1; then
  echo "User exists: $ADMIN_USER"
else
  useradd -m -s "$ZSH_BIN" -G "$SUDO_GROUP" "$ADMIN_USER"
  echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
fi

# --- SSH keys (with lockout guard) ---
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"

if valid_authkeys "$SRC_AUTH_KEYS"; then
  install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" \
    "$SRC_AUTH_KEYS" "/home/$ADMIN_USER/.ssh/authorized_keys"
  echo "Installed authorized_keys from: $SRC_AUTH_KEYS"
else
  # Defense-in-depth: the early preflight already guarantees a key, but never
  # disable password auth without one — that is an instant lockout.
  echo "ERROR: no usable SSH public key at: $SRC_AUTH_KEYS — aborting before sshd changes." >&2
  exit 1
fi

# --- sudo NOPASSWD ---
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
cat > /etc/sudoers.d/99-admin-nopasswd <<SUDOEOF
%${SUDO_GROUP} ALL=(ALL:ALL) NOPASSWD: ALL
SUDOEOF
chmod 440 /etc/sudoers.d/99-admin-nopasswd

# FIX: make sure /etc/sudoers actually reads the drop-in dir, else the file
# above is ignored. (Defensive — most distros already have this line.)
if ! grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  cp -a /etc/sudoers "/etc/sudoers.bak.$$"
  printf '@includedir /etc/sudoers.d\n' >> /etc/sudoers
  if ! visudo -c >/dev/null; then
    echo "sudoers validation failed, rolling back." >&2
    mv "/etc/sudoers.bak.$$" /etc/sudoers
    exit 1
  fi
  rm -f "/etc/sudoers.bak.$$"
else
  visudo -c >/dev/null
fi

# --- SSH hardening ---
SSHD_MAIN="/etc/ssh/sshd_config"
mkdir -p /etc/ssh/sshd_config.d

# FIX: fresh installs may not have host keys yet -> `sshd -t` would fail.
ssh-keygen -A >/dev/null 2>&1 || true

# FIX: Gentoo's (and some older) sshd_config has no `Include` line, so the
# drop-in below would have ZERO effect. Inject it at the very top if missing.
if [[ -f "$SSHD_MAIN" ]] && \
   ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_MAIN"; then
  { printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'; cat "$SSHD_MAIN"; } > "$SSHD_MAIN.new"
  cat "$SSHD_MAIN.new" > "$SSHD_MAIN"   # keep original perms/inode
  rm -f "$SSHD_MAIN.new"
fi

cat > /etc/ssh/sshd_config.d/99-bootstrap-security.conf <<SSHEOF
Port ${SSH_PORT}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
UsePAM yes
SSHEOF

# If the resulting config is invalid, remove our drop-in so we never leave a
# broken sshd that would fail to start on the next restart or reboot.
if ! sshd -t; then
  echo "ERROR: sshd config test failed; removing our drop-in and aborting." >&2
  rm -f /etc/ssh/sshd_config.d/99-bootstrap-security.conf
  exit 1
fi

# --- tmux config ---
cat > "/home/$ADMIN_USER/.tmux.conf" <<'TMUXEOF'
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",xterm-256color:RGB"
set -g history-limit 100000
set -g mouse on
setw -g mode-keys vi
set -g set-clipboard on
set -sg escape-time 0
set -g focus-events on

unbind C-b
set -g prefix C-a
bind C-a send-prefix

unbind %
bind | split-window -h -c "#{pane_current_path}"
unbind '"'
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind r source-file ~/.tmux.conf \; display-message "tmux config reloaded"

set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-selection-and-cancel
bind [ copy-mode

set -g status-position bottom
set -g status-style "bg=black,fg=white"
set -g status-left "#[bold] #S "
set -g status-right "#[fg=cyan]%Y-%m-%d #[fg=green]%H:%M "
setw -g window-status-format " #I:#W "
setw -g window-status-current-format "#[bold][#I:#W]"
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=green"
TMUXEOF

# --- zsh config ---
cat > "/home/$ADMIN_USER/.zshrc" <<'ZSHEOF'
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
export EDITOR="vim"
export VISUAL="vim"
export TERMINAL="xterm-256color"

HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS HIST_SAVE_NO_DUPS HIST_REDUCE_BLANKS INC_APPEND_HISTORY
setopt AUTO_CD INTERACTIVE_COMMENTS NO_BEEP EXTENDED_GLOB
setopt COMPLETE_IN_WORD ALWAYS_TO_END

autoload -Uz compinit
mkdir -p ~/.cache/zsh
zstyle ':completion:*' menu no
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' '+r:|[._-]=* r:|=*'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.cache/zsh/.zcompcache
[[ -d ~/.zsh/plugins/zsh-completions/src ]] && fpath=(~/.zsh/plugins/zsh-completions/src $fpath)

if [[ -n ~/.cache/zsh/.zcompdump(#qN.mh+24) ]]; then
  compinit -d ~/.cache/zsh/.zcompdump
else
  compinit -C -d ~/.cache/zsh/.zcompdump
fi

[[ -f ~/.cache/zsh/antidote.zsh ]] && source ~/.cache/zsh/antidote.zsh
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

bindkey '^ ' autosuggest-accept 2>/dev/null || true

zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath 2>/dev/null || ls -1 $realpath'

double-esc-sudo() {
  if [[ -z "$BUFFER" ]]; then
    zle up-history
  fi
  [[ "$BUFFER" == sudo\ * ]] || BUFFER="sudo $BUFFER"
  zle end-of-line
}
zle -N double-esc-sudo
bindkey '\e\e' double-esc-sudo

bindkey -e
bindkey '^A' beginning-of-line
bindkey '^E' end-of-line
bindkey '^U' backward-kill-line
bindkey '^K' kill-line
bindkey '^R' history-incremental-search-backward

alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias cls='clear'
alias reload='exec zsh'

command -v eza >/dev/null 2>&1 && alias ls='eza --group-directories-first --icons=auto'
command -v batcat >/dev/null 2>&1 && alias cat='batcat --paging=never'
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v atuin >/dev/null 2>&1 && eval "$(atuin init zsh)"

zsh-update-plugins() {
  [[ -d ~/.antidote ]] && git -C ~/.antidote pull --ff-only
  [[ -d ~/.zsh/plugins/zsh-completions ]] && git -C ~/.zsh/plugins/zsh-completions pull --ff-only
  source ~/.antidote/antidote.zsh
  antidote update
  antidote bundle < ~/.zsh_plugins.txt > ~/.cache/zsh/antidote.zsh
  echo "plugins updated. run: exec zsh"
}
ZSHEOF

chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.zshrc" "/home/$ADMIN_USER/.tmux.conf"

# --- install antidote + plugins as the admin user ---
# FIX 1: run with `-H` so $HOME points to /home/$ADMIN_USER (not /root).
#        Without it, mkdir/git wrote to the wrong home or failed on permission,
#        and .zshrc then sourced files that did not exist.
# FIX 2: run the block under ZSH, not bash — antidote is zsh code and cannot
#        be sourced/run from bash, so the pre-built bundle never generated.
sudo -u "$ADMIN_USER" -H "$ZSH_BIN" <<'USERSETUP' || \
  echo "WARNING: zsh plugin setup incomplete (check network). Shell still works; re-run zsh-setup.sh later — see README."
set -u
mkdir -p "$HOME/.cache/zsh" "$HOME/.zsh/plugins"

clone_or_pull() {  # <url> <dest>
  if [[ -d "$2/.git" ]]; then
    git -C "$2" pull --ff-only 2>/dev/null || true
  else
    rm -rf "$2"
    git clone --depth=1 "$1" "$2"
  fi
}
clone_or_pull https://github.com/mattmc3/antidote.git          "$HOME/.antidote" || exit 1
clone_or_pull https://github.com/zsh-users/zsh-completions.git "$HOME/.zsh/plugins/zsh-completions" || true

cat > "$HOME/.zsh_plugins.txt" <<'PLUGINS'
romkatv/powerlevel10k
Aloxaf/fzf-tab
zsh-users/zsh-autosuggestions
PLUGINS

source "$HOME/.antidote/antidote.zsh"
antidote bundle < "$HOME/.zsh_plugins.txt" > "$HOME/.cache/zsh/antidote.zsh"

# FIX: verify the bundle is non-empty (was silently skipped before -> bare prompt).
[[ -s "$HOME/.cache/zsh/antidote.zsh" ]]
USERSETUP

# --- enable + (re)start SSH, init-system aware ---
restart_ssh() {
  case "$INIT_SYS" in
    systemd)
      systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
      # FIX: modern Debian/Ubuntu use socket activation — the listening Port
      # lives in ssh.socket, NOT in sshd_config. Override it or the new port
      # is silently ignored.
      for sock in "${SSH_SERVICE}.socket" ssh.socket; do
        if systemctl list-unit-files "$sock" >/dev/null 2>&1 \
           && systemctl is-enabled "$sock" >/dev/null 2>&1; then
          mkdir -p "/etc/systemd/system/${sock}.d"
          cat > "/etc/systemd/system/${sock}.d/override.conf" <<SOCKEOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
SOCKEOF
          systemctl daemon-reload
          systemctl restart "$sock" || true
        fi
      done
      systemctl restart "$SSH_SERVICE"
      ;;
    openrc)
      rc-update add "$SSH_SERVICE" default >/dev/null 2>&1 || true
      rc-service "$SSH_SERVICE" restart 2>/dev/null || rc-service "$SSH_SERVICE" start
      ;;
    sysv)
      service "$SSH_SERVICE" restart 2>/dev/null || service "$SSH_SERVICE" start
      ;;
    *)
      echo "WARNING: unknown init system; restart '$SSH_SERVICE' manually." >&2
      ;;
  esac
}
restart_ssh

echo
echo "========== DONE =========="
echo "USER: $ADMIN_USER"
echo "PASS: $ADMIN_PASS"
echo "SSH:  ssh -p $SSH_PORT $ADMIN_USER@YOUR_SERVER_IP"
echo
echo "Test in a NEW terminal BEFORE closing this session:"
echo "  ssh -p $SSH_PORT $ADMIN_USER@YOUR_SERVER_IP"
echo "  sudo -n id"
echo "  tmux"
echo "  p10k configure"
echo
echo "Password SSH is disabled. Do not close this session before the new login works."
