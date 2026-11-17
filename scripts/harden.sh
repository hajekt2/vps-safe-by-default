#!/usr/bin/env bash
# Close a VPS to everything except the tailnet and Cloudflare.
#
# Order is the point: enroll Tailscale, prove the tailnet address, then close
# public SSH. Run from the temporary public SSH session.
#
# Environment:
#   WEB_MODE                 tunnel | cloudflare | none   (default: cloudflare)
#   TAILSCALE_AUTH_KEY       reusable tailnet auth key; read on stdin, never argv
#   CLOUDFLARE_TUNNEL_TOKEN  required only for WEB_MODE=tunnel
#   SSH_PORT                 current SSH port (default: 22)
#   TAILSCALE_HOSTNAME       tailnet name for this host (default: system hostname)
#
# Usage:
#   WEB_MODE=cloudflare TAILSCALE_AUTH_KEY=tskey-... sudo -E ./scripts/harden.sh
set -Eeuo pipefail

WEB_MODE="${WEB_MODE:-cloudflare}"
SSH_PORT="${SSH_PORT:-22}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname -s)}"

CF_V4_URL=https://www.cloudflare.com/ips-v4
CF_V6_URL=https://www.cloudflare.com/ips-v6
SSHD_CONFIG=/etc/ssh/sshd_config.d/99-closed-by-default.conf

log() { printf '  %s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

[[ ${1-} == --help || ${1-} == -h ]] && { usage; exit 0; }

[[ $EUID -eq 0 ]] || die "run as root: sudo -E $0"
[[ $WEB_MODE =~ ^(tunnel|cloudflare|none)$ ]] || die "WEB_MODE must be tunnel, cloudflare or none"
[[ $SSH_PORT =~ ^[0-9]+$ ]] || die "SSH_PORT must be a number"
[[ $WEB_MODE == tunnel && -z $CLOUDFLARE_TUNNEL_TOKEN ]] \
  && die "WEB_MODE=tunnel needs CLOUDFLARE_TUNNEL_TOKEN"

command -v apt-get >/dev/null || die "this script supports Debian and Ubuntu only"

# ---------------------------------------------------------------- packages ---
export DEBIAN_FRONTEND=noninteractive

log "Installing base packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates ufw openssh-server >/dev/null

# ---------------------------------------------------------------- tailscale --
install_tailscale() {
    local id codename base
    id=$(. /etc/os-release && printf '%s' "${ID:-}")
    codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
    case "$id" in
        ubuntu) base=https://pkgs.tailscale.com/stable/ubuntu ;;
        debian) base=https://pkgs.tailscale.com/stable/debian ;;
        *) die "unsupported distribution for Tailscale: $id" ;;
    esac
    log "Installing Tailscale from $base ($codename)"
    curl -fsSL "$base/$codename.noarmor.gpg" \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg
    printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] %s %s main\n' \
        "$base" "$codename" > /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    apt-get install -y -qq tailscale >/dev/null
    systemctl enable --now tailscaled
}

tailnet_ip() { tailscale ip -4 2>/dev/null | head -n1 || true; }

enroll_tailscale() {
    install_tailscale

    if [[ -n $(tailnet_ip) ]]; then
        log "Tailscale already enrolled at $(tailnet_ip)"
    elif [[ -n $TAILSCALE_AUTH_KEY ]]; then
        log "Enrolling Tailscale"
        # The key goes in on stdin so it never appears in argv or ps output.
        printf '%s' "$TAILSCALE_AUTH_KEY" | tailscale up \
            --auth-key=file:/dev/stdin \
            --hostname="$TAILSCALE_HOSTNAME" \
            --accept-dns=false \
            --accept-routes=false \
            --ssh=false >/dev/null
    else
        log "No TAILSCALE_AUTH_KEY given; running interactive enrollment"
        tailscale up \
            --hostname="$TAILSCALE_HOSTNAME" \
            --accept-dns=false \
            --accept-routes=false \
            --ssh=false
    fi

    log "Waiting for a tailnet address"
    for _ in $(seq 1 30); do
        [[ $(tailnet_ip) == 100.* ]] && break
        sleep 2
    done

    local ip
    ip=$(tailnet_ip)
    [[ $ip == 100.* ]] \
        || die "no tailnet address yet ($ip). Public SSH stays open; rerun once Tailscale is up."
    log "Tailnet address: $ip"
}

# --------------------------------------------------------------------- sshd ---
harden_sshd() {
    log "Key-only SSH, validated before reload"
    install -d -m 0755 "$(dirname "$SSHD_CONFIG")"
    cat > "$SSHD_CONFIG" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding local
MaxAuthTries 3
LoginGraceTime 30
EOF
    sshd -t || die "sshd rejected $SSHD_CONFIG"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

# --------------------------------------------------------------------- ufw ---
cloudflare_ranges() {
    local ranges
    ranges=$(curl -fsS --max-time 15 -4 "$CF_V4_URL" | grep -E '^[0-9]') \
        || die "could not fetch Cloudflare IPv4 ranges"
    if curl -fsS --max-time 15 -6 "$CF_V6_URL" >/dev/null 2>&1; then
        ranges+=$'\n'
        ranges+=$(curl -fsS --max-time 15 -6 "$CF_V6_URL" | grep -E ':')
    fi
    printf '%s\n' "$ranges"
}

apply_ufw() {
    log "Default-deny inbound in ufw"
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default allow routed >/dev/null

    # The access path that survives closing public SSH.
    ufw allow in on tailscale0 proto tcp to any port "$SSH_PORT" \
        comment 'SSH over Tailscale only' >/dev/null

    case "$WEB_MODE" in
        cloudflare)
            log "Allowing 80/443 from Cloudflare ranges only"
            # One rule per port keeps the syntax boring and the diff readable.
            while read -r cidr; do
                [[ -z $cidr ]] && continue
                ufw allow proto tcp from "$cidr" to any port 80 \
                    comment 'Cloudflare origin ingress' >/dev/null
                ufw allow proto tcp from "$cidr" to any port 443 \
                    comment 'Cloudflare origin ingress' >/dev/null
            done < <(cloudflare_ranges)
            ;;
        tunnel)
            log "Leaving 80/443 closed; the tunnel reaches them from localhost"
            ;;
        none)
            log "No inbound web traffic"
            ;;
    esac

    ufw --force enable >/dev/null
    ufw reload >/dev/null
}

install_cloudflared() {
    [[ $WEB_MODE == tunnel ]] || return 0
    if command -v cloudflared >/dev/null; then
        log "cloudflared already installed"
    else
        log "Installing cloudflared"
        install -d -m 0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            > /usr/share/keyrings/cloudflare-main.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
            > /etc/apt/sources.list.d/cloudflared.list
        apt-get update -qq
        apt-get install -y -qq cloudflared >/dev/null
    fi
    # The token lands in /etc/cloudflared/config.yml, not in the unit file.
    cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN" >/dev/null
    systemctl enable --now cloudflared
    log "Tunnel service: $(systemctl is-active cloudflared)"
}

# -------------------------------------------------------------------- main ---
enroll_tailscale
harden_sshd
apply_ufw
install_cloudflared

log "Done. Inbound now: $(ufw show default | tr '\n' ' ')"
log "Next: sudo ./scripts/verify.sh"
log "Then run the external probe from a machine outside the tailnet."
