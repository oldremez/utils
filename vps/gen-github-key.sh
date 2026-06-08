#!/usr/bin/env bash
# =============================================================================
# vps/gen-github-key.sh — Generate an SSH deploy key for GitHub
#
# Run as your normal user (not root):  bash gen-github-key.sh
# =============================================================================
set -euo pipefail

KEY_PATH="$HOME/.ssh/id_ed25519_github"
COMMENT="${USER}@$(hostname)"
SSH_CONFIG="$HOME/.ssh/config"

# ── Generate key ──────────────────────────────────────────────────────────────
if [[ ! -f "$KEY_PATH" ]]; then
    ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_PATH" -N ""
    echo "✓  Key generated: $KEY_PATH"
else
    echo "✓  Key already exists, skipping generation: $KEY_PATH"
fi

# ── Add GitHub block to ~/.ssh/config ────────────────────────────────────────
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
    mkdir -p "$HOME/.ssh"
    cat >> "$SSH_CONFIG" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
EOF
    chmod 600 "$SSH_CONFIG"
    echo "✓  GitHub entry added to $SSH_CONFIG"
else
    echo "✓  GitHub entry already in $SSH_CONFIG, skipping"
fi

# ── Print public key ──────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Copy this public key → GitHub repo → Settings → Deploy keys"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat "${KEY_PATH}.pub"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  After adding to GitHub, test with:  ssh -T git@github.com"
echo ""
