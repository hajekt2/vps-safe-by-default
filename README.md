# vps-safe-by-default

A fresh Hetzner or DigitalOcean server answers on every port. Port 22 is open to
the whole internet, and whatever you install next is open too, unless you
happen to know which checkbox to tick.

This repo is the recipe I use instead:

- the provider firewall and the host firewall both deny inbound by default
- SSH is reachable only over the tailnet
- web traffic arrives only through Cloudflare

It also includes a verifier, because "closed" is a claim you should be able to
check from inside and from outside.

Nothing here is novel. The point is the ordering, which is where people lock
themselves out.

## The three rules

1. **Deny inbound by default, in two places.** Attach a provider firewall at
   creation and set `ufw default deny incoming` on the host. One is the outer
   gate, the other is the gate that survives a provider misconfiguration.
2. **SSH only over the tailnet.** No port 22 rule from the internet, OpenSSH
   allowed only on `tailscale0`. Enrollment is outbound, so it works before
   inbound is closed and behind CGNAT.
3. **Web only through Cloudflare.** Either a Cloudflare Tunnel (`cloudflared`,
   zero inbound ports) or the Cloudflare proxy with 80/443 allowed only from
   Cloudflare's published ranges.

Both providers already default-deny **once a firewall is attached**. Hetzner
blocks all inbound when a firewall has no rules, and DigitalOcean blocks all
traffic not expressly permitted. The missing default is attaching one at
creation, not a missing feature.

## Order matters

This is the whole trick. Closing inbound before the tailnet path works is how
you lose a server.

1. Create the server with your SSH key and **no** port 22 firewall rule if your
   provider gives you one, or a temporary one restricted to your own address.
2. Enroll Tailscale. It only needs outbound.
3. Assert `tailscale ip -4` returns `100.x`. Do not continue on a guess.
4. Then close public SSH: `ufw default deny incoming`, allow 22 on `tailscale0`.
5. Verify from outside that nothing answers except web traffic.

`scripts/harden.sh` does steps 2-4 in that order and refuses to close SSH
without a tailnet address.

## Quick start

Human path, on a fresh Ubuntu 24.04 or Debian 12 host:

```sh
# still on the temporary public SSH
git clone https://github.com/hajekt2/vps-safe-by-default
cd vps-safe-by-default

WEB_MODE=cloudflare sudo -E ./scripts/harden.sh
sudo ./scripts/verify.sh
```

`WEB_MODE` controls inbound web traffic:

| Value | Inbound 80/443 | Use when |
|---|---|---|
| `tunnel` | closed to the internet | `cloudflared` carries traffic, server needs no public web port |
| `cloudflare` | open to Cloudflare ranges only | Caddy serves the origin behind the Cloudflare proxy |
| `none` | closed | tailnet-only service, no public web at all |

Agent path: point the agent at [`AGENTS.md`](AGENTS.md). It names the order, the
assertions, and the failure mode for each step.

## What it changes

| Path | Purpose |
|---|---|
| `cloud-init.yaml` | first boot: user, key-only SSH, ufw and Tailscale installed but not yet closing anything |
| `scripts/harden.sh` | idempotent: enroll, assert, close SSH to the tailnet, apply web ingress |
| `scripts/verify.sh` | checks the tailnet path, ufw policy, every listening socket, and Docker bindings |
| `templates/Caddyfile` | origin Caddy that trusts only the Cloudflare proxy |
| `templates/compose.yaml` | containers published to `127.0.0.1`, never to the world |
| `docs/pitfalls.md` | Docker and ufw, ACME behind the proxy, IPv6, lockout recovery |
| `docs/provider-defaults.md` | what each provider actually does by default, with commands |

## Verification

From the server, with `sudo`:

```sh
sudo ./scripts/verify.sh
```

Expected result: ufw active with a deny incoming default, one SSH rule scoped to
`tailscale0`, no listener on `0.0.0.0` except the SSH port and Caddy's 80/443
when `WEB_MODE=cloudflare`, and no Docker port published to the world.

A wildcard listener that ufw already drops is reported as a note, not a
failure. Bind it to `127.0.0.1` to clear the note; the reference setup does that
for every service, so a firewall mistake is not the only thing standing between
the internet and a database.

From another machine, the part the server cannot tell you:

```sh
nmap -Pn -p- --open 2.28.33.90      # only the ports you expect
nc -vz 2.28.33.90 22               # must fail: SSH is not on the public IP
curl -sS -o /dev/null -w '%{http_code}\n' https://your-host.example
```

Do the external probe from outside your tailnet. A tailnet client can reach port
22 over `tailscale0` and that is not evidence about the public path.

## What this does not do

- No bastion, no jump host, no VPN concentrator. Tailscale is the access path.
- No tailnet-side authorization policy. Add ACLs and tags if more than one
  person or agent can reach the tailnet.
- No IDS, WAF, or rate limiting. The WAF that matters is at Cloudflare.
- No secret management. Tokens here come from the environment or Bitwarden.

## Reference setup

The live version of this runs on a Hetzner `cx33` in `fsn1`: no `22` rule in the
committed cloud firewall at all, OpenSSH allowed only on `tailscale0`, 80/443
admitted only from Cloudflare's ranges, Caddy owning both ports, and every
application container published on `127.0.0.1`. The inventory, firewall, and
Tailscale roles are in [hajekt2/cloud-infra](https://github.com/hajekt2/cloud-infra).

## License

MIT. See [LICENSE](LICENSE).
