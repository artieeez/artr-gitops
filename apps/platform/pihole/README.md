# Pi-hole

- **DNS (tailnet):** Tailscale Kubernetes Operator exposes `pihole-dns` at `pihole-dns.<tailnet>.ts.net` (see `charts/pihole-values.yaml` annotations). Setup: [docs/tailscale-pihole-setup.md](../../../docs/tailscale-pihole-setup.md).
- **DNS (public):** None. Nothing listens on 53 or 853 in front of the internet: the OCI NLB carries HTTP/HTTPS and the games port only, and Traefik has no DNS entryPoints. Point devices at the tailnet name, not at the NLB IP.
- **Web UI:** `https://pihole.artr.com.br` — TLS at Traefik; access is gated by **TinyAuth** (`middlewares: [tinyauth-forwardauth]`). The `Middleware` CR lives with [sealed-secrets-web](../sealed-secrets-web/ingressroute.yaml); Pi-hole only references it.
- **Pi-hole admin password:** Disabled in Helm (`admin.enabled: false`); rely on TinyAuth for the dashboard.
- **Upstream DNS:** Managed in the web UI (**Settings → DNS**). Helm leaves `DNS1`/`DNS2` empty so `FTLCONF_dns_upstreams` is not injected (that env would lock the UI). Config survives restarts on the PVC.

## Clients

- **Machines on the tailnet** use Tailscale's global nameserver (see the setup guide) — nothing to configure per app.
- **Home LAN devices without Tailscale** cannot use Pi-hole. Options: run Tailscale on the device, advertise the home subnet from a subnet router, or fall back to the router's own resolver. Do **not** re-add a public 53 listener: Pi-hole would become an open resolver reachable from the internet.

## Troubleshooting

1. **No `pihole-dns` machine in Tailscale admin:** check the operator (`kubectl -n tailscale logs -l app=operator`) and the `operator-oauth` SealedSecret.

2. **`dig @pihole-dns.<tailnet>.ts.net` times out:** Pi-hole pod health (`kubectl -n platform get pods -l app=pihole`) and `FTLCONF_dns_listeningMode: all` in `charts/pihole-values.yaml`.

3. **Queries resolve but ads are not blocked:** the tailnet global nameserver is not Pi-hole, or the fallback resolver is answering first.

4. **A device still points at the old NLB IP for DNS:** it will now time out. Switch it to the tailnet name (or to a public resolver).
