#!/usr/bin/env bash
# =============================================================================
# vps/setup.sh — Idempotent Ubuntu VPS bootstrapper
#
# Usage (local):   bash setup.sh
# Usage (remote):  bash <(curl -fsSL https://raw.githubusercontent.com/kai/utils/main/vps/setup.sh)
#
# What it does:
#   1. Updates the system
#   2. Installs base packages (git, vim, tmux, …)
#   3. Installs fish shell
#   4. Installs Docker from the official repo
#   5. Creates user + adds to sudo & docker groups
#   6. Copies SSH keys from root → new user
#   7. Hardens SSH (no root login, no password auth)
#   8. Configures UFW firewall
# =============================================================================
set -euo pipefail

# ── CONFIG (only thing you should need to edit) ───────────────────────────────
USERNAME="kai"
BASE_PACKAGES=(git vim tmux curl wget unzip build-essential htop)
# ─────────────────────────────────────────────────────────────────────────────

# ── COLORS & HELPERS ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "\n${CYAN}▶  $*${NC}"; }
ok()   { echo -e "   ${GREEN}✓${NC}  $*"; }
warn() { echo -e "   ${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "\n${RED}✗  $*${NC}\n"; exit 1; }

# ── PREFLIGHT ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run this script as root"
command -v apt-get &>/dev/null || die "This script requires apt (Ubuntu/Debian only)"

# ── 1. SYSTEM UPDATE ─────────────────────────────────────────────────────────
info "Updating system packages…"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System up to date"

# ── 2. BASE PACKAGES ─────────────────────────────────────────────────────────
info "Installing base packages: ${BASE_PACKAGES[*]}…"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${BASE_PACKAGES[@]}"
ok "Base packages installed"

# ── 3. FISH SHELL ────────────────────────────────────────────────────────────
info "Installing fish shell…"
if ! command -v fish &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fish
    ok "Fish installed: $(fish --version)"
else
    ok "Fish already installed: $(fish --version)"
fi

# Ensure fish is listed in /etc/shells (needed for chsh)
FISH_PATH="$(which fish)"
grep -qxF "$FISH_PATH" /etc/shells || echo "$FISH_PATH" >> /etc/shells

# ── 4. DOCKER (official repo, not the Ubuntu-packaged one) ───────────────────
info "Installing Docker from the official repo…"
if ! command -v docker &>/dev/null; then
    apt-get install -y -qq ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Fall back to UBUNTU_CODENAME if VERSION_CODENAME is absent (some minimal images)
    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed: $(docker --version)"
else
    ok "Docker already installed: $(docker --version)"
fi

# ── 5. USER SETUP ────────────────────────────────────────────────────────────
info "Setting up user: $USERNAME…"

if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s "$FISH_PATH" "$USERNAME"
    ok "User $USERNAME created"
else
    chsh -s "$FISH_PATH" "$USERNAME"   # Ensure fish is the shell even if user existed
    ok "User $USERNAME already exists — shell updated to fish"
fi

usermod -aG sudo,docker "$USERNAME"
ok "$USERNAME added to sudo & docker groups"

# Passwordless sudo — convenient for a dev VPS.
# Remove the NOPASSWD flag below if you want sudo to prompt for a password.
SUDOERS_FILE="/etc/sudoers.d/$USERNAME"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    ok "Sudoers entry created (NOPASSWD)"
else
    ok "Sudoers entry already exists"
fi

# ── 6. COPY SSH KEYS root → new user ─────────────────────────────────────────
info "Configuring SSH keys for $USERNAME…"
USER_HOME="/home/$USERNAME"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if [[ -f /root/.ssh/authorized_keys ]]; then
    if [[ ! -f "$AUTH_KEYS" ]]; then
        mkdir -p "$SSH_DIR"
        cp /root/.ssh/authorized_keys "$AUTH_KEYS"
        chmod 700 "$SSH_DIR"
        chmod 600 "$AUTH_KEYS"
        chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
        ok "SSH authorized_keys copied from root → $USERNAME"
    else
        ok "authorized_keys already exists for $USERNAME — skipping copy"
    fi
else
    warn "No /root/.ssh/authorized_keys found."
    warn "Before SSH hardening takes effect, manually run:"
    warn "  mkdir -p $SSH_DIR"
    warn "  echo 'YOUR_PUBLIC_KEY' >> $AUTH_KEYS"
    warn "  chmod 700 $SSH_DIR && chmod 600 $AUTH_KEYS"
    warn "  chown -R $USERNAME:$USERNAME $SSH_DIR"
fi

# ── 7. SSH HARDENING ─────────────────────────────────────────────────────────
info "Hardening SSH daemon…"
SSHD_CONF="/etc/ssh/sshd_config"
cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

# Helper: set or uncomment a directive in sshd_config
set_sshd() {
    local key="$1" val="$2"
    if grep -qE "^#?\s*${key}\s" "$SSHD_CONF"; then
        sed -i -E "s|^#?\s*${key}\s.*|${key} ${val}|" "$SSHD_CONF"
    else
        echo "${key} ${val}" >> "$SSHD_CONF"
    fi
}

set_sshd "PermitRootLogin"                 "no"
set_sshd "PasswordAuthentication"          "no"
set_sshd "ChallengeResponseAuthentication" "no"
set_sshd "X11Forwarding"                   "no"
set_sshd "MaxAuthTries"                    "3"

# Validate config before reloading — avoids locking yourself out
sshd -t || die "sshd config validation failed — check $SSHD_CONF and its .bak"
systemctl reload sshd
ok "SSH hardened (root login & password auth disabled)"

# ── 8. FIREWALL (UFW) ────────────────────────────────────────────────────────
info "Configuring UFW firewall…"
if ! command -v ufw &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
fi

ufw --force reset        > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow ssh            > /dev/null   # port 22 — change if you use a custom port
ufw --force enable       > /dev/null
ok "UFW enabled (inbound: SSH only)"

# ── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo ""
echo -e "  Connect as:  ${CYAN}ssh ${USERNAME}@<your-server-ip>${NC}"
echo ""
echo -e "  ${YELLOW}⚠  IMPORTANT — before closing this session:${NC}"
echo -e "     Open a new terminal and confirm SSH works as $USERNAME."
echo -e "     Root login is now disabled — don't close this window until verified."
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
