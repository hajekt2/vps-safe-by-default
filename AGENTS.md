# AGENTS.md

Instructions for an agent asked to make a VPS safe by default. Read this whole
file before touching the host.

## Goal

After you finish, the host must satisfy all four statements, proven by command
output you actually ran:

1. `ufw` is active with `deny (incoming)` as the default policy.
2. OpenSSH accepts connections on port 22 only through `tailscale0`.
3. No listener is bound to a public address, except the web ports the chosen
   `WEB_MODE` requires.
4. No container port is published to `0.0.0.0`.

Do not claim any of these from configuration files alone. Run
`scripts/verify.sh` and paste its output.

## Non-negotiable order

1. Confirm you can log in over the current public SSH path.
2. Enroll Tailscale: `tailscale up`, or `harden.sh` with `TAILSCALE_AUTH_KEY`.
3. Assert `tailscale ip -4` returns an address starting with `100.`.
4. Only then close public SSH.
5. Verify.

If step 3 fails, stop and leave port 22 open. A host with open SSH is a smaller
problem than a host nobody can reach. Before step 4, confirm how to regain
access without SSH: provider web console, rescue system, or serial console.

## Before you start

Ask the operator, or read from the environment, and never invent:

| Input | Why it matters |
|---|---|
| `WEB_MODE` (`tunnel`, `cloudflare`, `none`) | decides whether 80/443 are open at all |
| `TAILSCALE_AUTH_KEY` | a reusable, pre-authorized tailnet key; revoke it after use |
| `CLOUDFLARE_TUNNEL_TOKEN` | only for `WEB_MODE=tunnel` |
| `SSH_PORT` | the port the host listens on now; default 22 |
| public hostname | the name Cloudflare fronts, for the external check |

Never echo a token or auth key into output, logs, or a commit. `harden.sh`
passes the Tailscale key on stdin.

## Steps

```sh
# 1. Inspect what exists before changing anything
sudo ss -lntup
sudo ufw status verbose
tailscale status

# 2. Harden; this is the only mutating step
WEB_MODE=cloudflare TAILSCALE_AUTH_KEY="$(cat /run/secrets/ts-key)" \
  sudo -E ./scripts/harden.sh

# 3. Prove it
sudo ./scripts/verify.sh
```

For `WEB_MODE=cloudflare`, the provider firewall must also admit 80 and 443 from
Cloudflare's ranges. Prefer doing that at the provider. `harden.sh` repeats the
allowlist in `ufw` so a provider mistake is not the only gate.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `verify.sh` reports no `100.x` address | enrollment never completed, or DNS blocked the key exchange | run `tailscale up` interactively, check `tailscale status` |
| SSH works from the tailnet but not from the operator's laptop | the laptop is not on the tailnet | enroll the laptop; do not reopen port 22 |
| A published port survives `ufw default deny` | Docker inserts its own DNAT rules before `ufw` | bind `127.0.0.1:PORT:PORT` or read `docs/pitfalls.md` |
| ACME challenge fails after hardening | DNS record is not proxied, so the CA reaches the origin from its own IPs | proxy the record, or issue with DNS-01 |
| Certificate issue hangs on a tunnel host | nothing listens on 80 at the origin | let Cloudflare terminate TLS; serve plain HTTP on `127.0.0.1` |
| IPv6 still answers | ufw or the provider firewall covers IPv4 only | check `IPV6=yes` in `/etc/default/ufw` and add `::/0` rules |

## Report

End with: the observed tailnet address, the `ufw` defaults, the exact listener
list from `verify.sh`, the external probe results, and anything you could not
verify. Name remaining risk instead of calling the host "secure".
