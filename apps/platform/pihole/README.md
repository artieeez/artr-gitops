# Pi-hole

- **DNS:** Same public IP as Traefik. UDP/TCP **53** are forwarded by Traefik (`dnsudp` / `dnstcp` entryPoints in `charts/traefik-values.yaml`) to `pihole-dns` via `IngressRouteUDP` / `IngressRouteTCP`.
- **Web UI:** `https://pihole.artr.com.br` — TLS at Traefik; access is gated by **TinyAuth** (`middlewares: [tinyauth-forwardauth]`). The `Middleware` CR lives with [sealed-secrets-web](../sealed-secrets-web/ingressroute.yaml); Pi-hole only references it.
- **Pi-hole admin password:** Disabled in Helm (`admin.enabled: false`); rely on TinyAuth for the dashboard.

Point your router’s DNS to the **Traefik NLB** IP (same as `*.artr.com.br`).
