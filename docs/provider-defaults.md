# Provider defaults

What a fresh server actually looks like, checked against provider documentation
in November 2026. Provider behaviour changes; re-read the linked page before
quoting it.

## Hetzner Cloud

| Question | Answer |
|---|---|
| Is a firewall attached to a new server? | Only if you pass one at creation (`hcloud server create --firewall ...`) or match a label selector |
| No firewall attached | Every port answers: 22, 80, 443, whatever you install |
| Firewall attached, no rules | All inbound blocked, all outbound permitted |
| Stateful? | Yes |
| Price | Free |

Source: <https://docs.hetzner.com/cloud/firewalls/overview/>. The relevant line:
"If you do not set any rule, all inbound traffic will automatically be blocked
and all outbound traffic will automatically be permitted."

So Hetzner already gives you safe by default, if you attach an empty or
SSH-scoped firewall in the create call. The gap is that the create call does not
require one.

```sh
# Create the closed firewall first, then create the server with it attached.
hcloud firewall create --name closed-by-default
hcloud firewall add-rule closed-by-default \
  --direction in --protocol tcp --port 443 \
  --source-ips 173.245.48.0/20 --source-ips 103.21.244.0/22   # Cloudflare ranges

hcloud server create --name web01 --type cx33 --image ubuntu-24.04 \
  --location fsn1 --ssh-key operator --firewall closed-by-default
```

For the full Cloudflare set, fetch `https://www.cloudflare.com/ips-v4` and
`https://www.cloudflare.com/ips-v6` and pass every range. Repeat `--source-ips`
per range, or use `--rules-file` with the API JSON shape when the list grows.

`cloud-apps-prod-01`, the reference host for this repo, runs with **no port 22
rule at all**: administrative SSH only exists through `tailscale0`.
See [hajekt2/cloud-infra](https://github.com/hajekt2/cloud-infra) at
`systems/shared-app-host-prod`.

## DigitalOcean

| Question | Answer |
|---|---|
| Is a cloud firewall enabled on a new Droplet? | No. It must be created and assigned |
| No cloud firewall assigned | Every port answers, including 22 and 80 |
| Assigned, no rules | All traffic not expressly permitted is blocked |
| Stateful? | Yes |
| Price | Free |

Source: <https://docs.digitalocean.com/products/networking/firewalls/>. The
relevant line: "Cloud firewalls block all traffic that isn't expressly permitted
by a rule."

```sh
# Illustrative; run "doctl compute firewall create --help" for your doctl version.
doctl compute firewall create closed-by-default \
  --inbound-rules "protocol:tcp,ports:443,address:0.0.0.0/0" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0" \
  --droplet-ids <droplet-id>
```

Do not leave `ports:22,address:0.0.0.0/0` after Tailscale enrollment. DigitalOcean
has no tailnet-aware rule type, so port 22 is closed at the cloud firewall and
OpenSSH stays reachable through `tailscale0` on the host.

## What "default" should mean

The ask to both providers is a creation-time default, not a new feature:

1. A firewall exists on the server at first boot, denying inbound.
2. SSH is optional on the public interface, off once a tailnet path is proven.
3. Web ingress is scoped to the edge in front of it, or closed entirely when a
   tunnel is used.

Both companies already have every mechanism. The default create path just does
not use them.
