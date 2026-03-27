# Pi-hole

- **DNS:** Same public IP as Traefik. UDP/TCP **53** are forwarded by Traefik (`dnsudp` / `dnstcp` entryPoints in `charts/traefik-values.yaml`) to `pihole-dns` via `IngressRouteUDP` / `IngressRouteTCP`.
- **DNS-over-TLS (DoT):** `pihole.artr.com.br:853` via Traefik `dottcp` entryPoint and `IngressRouteTCP` TLS termination.
- **Web UI:** `https://pihole.artr.com.br` — TLS at Traefik; access is gated by **TinyAuth** (`middlewares: [tinyauth-forwardauth]`). The `Middleware` CR lives with [sealed-secrets-web](../sealed-secrets-web/ingressroute.yaml); Pi-hole only references it.
- **Pi-hole admin password:** Disabled in Helm (`admin.enabled: false`); rely on TinyAuth for the dashboard.

Point your router’s DNS to the **Traefik NLB** IP (same as `*.artr.com.br`).

## Troubleshooting “router DNS doesn’t work”

1. **Terraform `dns_server_allowed_cidrs`** (oracle-cluster) must include the **public WAN IP** that OCI sees when your home network queries the NLB (usually `/32`). If it’s wrong or empty, **UDP/TCP 53 are dropped** while HTTPS on 443 still works.

2. **Isolate router vs Pi-hole:** From a laptop on the LAN, run:
   - `dig @<NLB_IP> cloudflare.com` (UDP)
   - `dig @<NLB_IP> cloudflare.com +tcp` (TCP)  
   If TCP works but UDP does not, check OCI **UDP** rules and Traefik/NLB UDP listeners.

3. **Some routers** ignore “custom DNS” for clients or use ISP caching; try setting DNS on **one device** to the NLB IP to confirm.

4. If **UDP fails but `dig +tcp` works** (even from LTE), the usual fix is **`nativeLB: false`** on `IngressRouteUDP` / `IngressRouteTCP` so Traefik targets **pod IPs** instead of kube-proxy/ClusterIP (UDP often breaks on the ClusterIP path). If it still fails, verify the Traefik `Service` has a **UDP** port **53** and the OCI NLB shows a **UDP** listener; last resort is a **separate LoadBalancer** for `pihole-dns` (bypass Traefik on 53).
