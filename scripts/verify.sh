#!/usr/bin/env bash
# Prove the host is closed. Checks the access path, the firewall policy, every
# listening socket, and Docker bindings.
#
# Environment:
#   SSH_PORT     port SSH listens on (default: 22)
#   WEB_MODE     tunnel | cloudflare | none   (default: cloudflare)
#   PUBLIC_IP    optional public address; a listener bound to it is a failure
#   PUBLIC_HOST  optional public hostname for an HTTP check through Cloudflare
#
# Usage:
#   sudo ./scripts/verify.sh
set -Eeuo pipefail

SSH_PORT="${SSH_PORT:-22}"
WEB_MODE="${WEB_MODE:-cloudflare}"
PUBLIC_IP="${PUBLIC_IP:-}"
PUBLIC_HOST="${PUBLIC_HOST:-}"

failures=0
notes=0
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '  note  %s\n' "$*"; notes=$((notes + 1)); }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
[[ ${1-} == --help || ${1-} == -h ]] && { usage; exit 0; }
[[ $EUID -eq 0 ]] || { printf 'run as root: sudo %s\n' "$0" >&2; exit 2; }
[[ $WEB_MODE =~ ^(tunnel|cloudflare|none)$ ]] || { printf 'bad WEB_MODE\n' >&2; exit 2; }

printf '\n1. Tailnet access path\n'

tailnet_ips=$(tailscale ip 2>/dev/null || true)
if grep -q '^100\.' <<<"$tailnet_ips"; then
    ok "tailnet address $(grep '^100\.' <<<"$tailnet_ips" | head -n1)"
else
    bad "no 100.x tailnet address; tailscaled is down or not enrolled"
fi

if tailscale status >/dev/null 2>&1; then
    ok "tailscaled reports a running backend"
else
    bad "tailscale status failed"
fi

printf '\n2. ufw policy\n'

ufw_active=0
[[ $(ufw status 2>/dev/null | head -n1) == 'Status: active' ]] && ufw_active=1
if ((ufw_active)); then
    ok "ufw active"
else
    bad "ufw is not active"
fi

ufw_deny=0
defaults=$(ufw show default 2>/dev/null || true)
if grep -q 'deny (incoming)' <<<"$defaults"; then
    ufw_deny=1
    ok "default deny incoming"
else
    bad "default incoming policy is not deny"
fi
if grep -q 'allow (outgoing)' <<<"$defaults"; then
    ok "default allow outgoing"
else
    note "outgoing is not allow; confirm every needed egress rule exists"
fi

if grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
    ok "ufw covers IPv6"
else
    bad "IPV6=yes missing in /etc/default/ufw; IPv6 bypasses these rules"
fi

printf '\n3. SSH scope\n'

if command -v iptables >/dev/null; then
    ssh_rules=$(iptables -S 2>/dev/null | grep -E -- "--dport ${SSH_PORT}( |$)" || true)
    if [[ -z $ssh_rules ]]; then
        bad "no iptables rule admits port $SSH_PORT; the tailnet path may be broken"
    elif grep -v -- '-i tailscale0' <<<"$ssh_rules" >/dev/null; then
        # Every rule admitting SSH must be scoped to tailscale0. An unscoped
        # rule means public SSH is still open.
        bad "port $SSH_PORT is admitted without an interface scope:"
        grep -v -- '-i tailscale0' <<<"$ssh_rules" | sed 's/^/        /'
    else
        ok "port $SSH_PORT admitted only on tailscale0"
    fi
else
    note "iptables not installed; cannot inspect the SSH rule scope"
fi

printf '\n4. Listening sockets\n'

# Wildcard listeners are reachable on every interface. Allowed: the SSH port
# (ufw scopes it) and, in cloudflare mode, 80 and 443. Everything else must bind
# loopback or a tailnet address.
allowed_public=("$SSH_PORT")
[[ $WEB_MODE == cloudflare ]] && allowed_public+=(80 443)

declare -A reported=()
while read -r netid _state _recv _send local _peer; do
    [[ $local == *:* ]] || continue
    host=${local%:*}
    port=${local##*:}

    case $host in
        127.*|'[::1]'|100.*|'[fd7a:'*) continue ;;
        '0.0.0.0'|'*'|'[::]') wildcard=1 ;;
        *) wildcard=0 ;;
    esac

    key="$netid:$port"
    [[ -n ${reported[$key]:-} ]] && continue
    reported[$key]=1

    if ((wildcard)); then
        if [[ " ${allowed_public[*]} " == *" $port "* ]]; then
            ok "wildcard :$port ($netid) is an expected SSH or web port"
        elif ((ufw_active && ufw_deny)); then
            # ufw drops unsolicited inbound, so this is not reachable today. It
            # is still one firewall mistake away from being reachable, which is
            # why the reference setup binds to loopback instead.
            note "wildcard :$port ($netid) is behind ufw; bind 127.0.0.1 for defence in depth"
        else
            bad "wildcard :$port ($netid) answers on every interface"
        fi
    elif [[ -n $PUBLIC_IP && $host == "$PUBLIC_IP" ]]; then
        bad "bound to the public address $host:$port ($netid)"
    else
        note "bound to $host:$port ($netid); fine only if $host is a private interface"
    fi
done < <(ss -lntuH 2>/dev/null)

printf '\n5. Container bindings\n'

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    published=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
    if grep -E '0\.0\.0\.0:|:::' <<<"$published" >/dev/null; then
        bad "a container publishes to the world; ufw does not filter these:"
        grep -E '0\.0\.0\.0:|:::' <<<"$published" | sed 's/^/        /'
    else
        ok "no container port published to 0.0.0.0 or [::]"
    fi
else
    note "docker not present or not running"
fi

printf '\n6. Web path\n'

if [[ -n $PUBLIC_HOST ]]; then
    if curl -fsS -o /dev/null --max-time 10 "https://$PUBLIC_HOST/"; then
        ok "https://$PUBLIC_HOST answers"
    else
        bad "https://$PUBLIC_HOST does not answer"
    fi
else
    note "set PUBLIC_HOST to check the web path through Cloudflare"
fi

printf '\nOutside checks, from a machine off the tailnet:\n'
cat <<EOF
  nmap -Pn -p- --open ${PUBLIC_IP:-<public-ip>}   # expect only the ports you allowed
  nc -vz ${PUBLIC_IP:-<public-ip>} $SSH_PORT             # must fail
  curl -sS -o /dev/null -w '%{http_code}\\n' https://${PUBLIC_HOST:-<host>}

EOF

if ((failures > 0)); then
    printf '%d check(s) failed, %d note(s)\n\n' "$failures" "$notes"
    exit 1
fi
printf 'All checks passed, %d note(s). Confirm the external probe too; that is the part this host cannot see.\n\n' "$notes"
