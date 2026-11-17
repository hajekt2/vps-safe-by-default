# Pitfalls

The rules are simple. These are the things that silently break them.

## Docker publishes ports ahead of ufw

Docker writes its own DNAT and filter rules into `nat` and `DOCKER*` chains.
Packet flow reaches them before `ufw-user-input`, so a container published with
`-p 8080:80` answers on the public IP even though `ufw default deny incoming`
says otherwise. This is the most common way a "closed" host is still open.

Three fixes, in order of preference:

1. Publish to loopback: `-p 127.0.0.1:8080:80`, and let Caddy own 80/443.
2. Publish nothing: keep services on a Compose network and route through Caddy
   on the same network, or through `network_mode: host` only for Caddy.
3. Filter Docker traffic explicitly with `ufw-docker` or a `DOCKER` chain jump.

`verify.sh` checks both the listening sockets and `docker ps` output.

## Closing inbound before the tailnet path works

`tailscale up` needs outbound only, so it works while port 22 is still open and
it works behind CGNAT. But if you close port 22 first, enrollment has to happen
from a provider console. Every provider has one; not every operator knows how to
find it under pressure.

Keep a second SSH session open while `harden.sh` runs. It ends with
`ufw --force reset`, so rules are briefly removed and re-added.

## Tailscale SSH is not the only option

`tailscale up --ssh` runs an SSH server inside `tailscaled`. It works, and it
does not need an OpenSSH listener at all.

This repo keeps OpenSSH and scopes it to `tailscale0` instead. Reasons: normal
`sshd_config`, normal `authorized_keys`, normal PAM/sudo accounting, and no
surprise when Tailscale's SSH feature changes. Pick one deliberately; running
both is confusing when you debug access.

## A grey-clouded DNS record breaks ACME HTTP-01

With the record proxied, the CA's validation request arrives from Cloudflare, so
a Cloudflare-only 80 allowlist is enough for certificate issuance. Grey-cloud
the record (DNS only) and the CA connects to your origin from its own IPs, which
the firewall drops. Fixes: use DNS-01 (Caddy and certbot both support it with a
Cloudflare API token), or stop pretending the origin is Cloudflare-only.

On a tunnel host, TLS terminates at the Cloudflare edge. Do not run ACME at the
origin at all; serve plain HTTP on `127.0.0.1` and let Cloudflare publish the
certificate.

## IPv6 is a second front door

Provider firewalls and `ufw` both need explicit v6 coverage:

- Hetzner and DigitalOcean firewall rules take `::/0` as a separate source.
- `ufw` only creates v6 rules when `/etc/default/ufw` has `IPV6=yes`.
- Docker publishes on `[::]` as well when the host has a public v6 address.

Check with `ss -lntu` after hardening, not only `ufw status`.

## Provider firewall rules are stateful, host rules may not be

Hetzner and DigitalOcean cloud firewalls are stateful: one inbound rule admits
the reply traffic. A hand-written `iptables`/`nftables` ruleset without
`ct state established,related accept` is not, and will break DNS and updates.
`ufw` is stateful by default.

## The tunnel is a supervised process, not a firewall

`cloudflared` is just an outbound client. It does not create inbound rules and
it does not protect anything else that listens. Two consequences:

- Keep it under systemd with a restart policy; a dead tunnel means a dead site,
  and nothing else reports it.
- Pass the token so it does not appear in `ps`. `cloudflared service install`
  writes it to `/etc/cloudflared/config.yml` instead of the unit file.

If only the tailnet needs the service, `tailscale serve` replaces the tunnel
entirely and needs no Cloudflare account.

## Lockout recovery, in order

1. Provider web console or rescue system (Hetzner console, DigitalOcean
   recovery console) opens a shell without SSH.
2. If your laptop is off the tailnet: enroll it, do not reopen port 22.
3. `tailscale status` after a crash: if the daemon exited, `tailscaled.state`
   still holds the login, so `systemctl restart tailscaled` reconnects without
   re-authenticating.
4. Only then, if the tailnet itself is broken, add a temporary provider firewall
   rule for port 22 from your own address and remove it after.

## "Safe by default" is a creation-time property

The provider default is the thing being fixed. Both Hetzner and DigitalOcean
already deny by default **when a firewall is attached**; a fresh server without
one is fully open. If you create servers by script, attach the firewall as an
argument of creation, not as a later step somebody can forget. See
[provider-defaults.md](provider-defaults.md).
