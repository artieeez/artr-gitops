# Tailscale + Pi-hole (MacBook & Android)

Pi-hole runs in the OCI cluster. This guide adds a **private tailnet DNS path** so your MacBook and Android phone always use Pi-hole when Tailscale is connected. The existing **public Traefik NLB** path (home router → NLB :53) is unchanged.

**GitOps changes** (already in repo after merge):

- Tailscale Kubernetes Operator (`platform-tailscale-operator`)
- Pi-hole `pihole-dns` Service annotated for tailnet expose (`charts/pihole-values.yaml`)

---

## Architecture

```text
Mac / Android  →  Tailscale (Override local DNS)  →  pihole-dns.<tailnet>.ts.net  →  Pi-hole pod
Home router    →  Traefik NLB :53                    →  Pi-hole pod   (unchanged)
```

---

## Prerequisites

- Tailscale account ([tailscale.com](https://tailscale.com))
- `kubectl` + cluster access (for SealedSecret)
- `kubeseal` (see [sealed-secrets.md](./sealed-secrets.md))

---

## Step 1 — Create a tailnet (if needed)

1. Sign up at [login.tailscale.com](https://login.tailscale.com).
2. Note your tailnet DNS name (e.g. `tail1234.ts.net`) under **DNS**.

---

## Step 2 — ACL tags for the Kubernetes operator

In **Access controls** → edit policy, ensure tag owners exist (merge with your existing policy):

```json
"tagOwners": {
  "tag:k8s-operator": ["autogroup:admin"],
  "tag:k8s": ["tag:k8s-operator"]
}
```

Save policy.

---

## Step 3 — OAuth client for the operator

1. **Settings → OAuth clients → Generate OAuth client**
2. Scopes: **Devices** (Write), **Auth Keys** (Write)
3. Tags: add **`tag:k8s-operator`**
4. Save **Client ID** and **Client Secret** (secret shown once)

---

## Step 4 — SealedSecret `operator-oauth`

From repo root, with cluster access:

```bash
kubectl -n tailscale create secret generic operator-oauth \
  --from-literal=client_id='<CLIENT_ID>' \
  --from-literal=client_secret='<CLIENT_SECRET>' \
  --dry-run=client -o yaml | \
kubeseal --format yaml \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets \
  > infrastructure/tailscale/operator-oauth-sealed.yaml
```

Commit `infrastructure/tailscale/operator-oauth-sealed.yaml`. ArgoCD will not apply the operator successfully until this Secret decrypts in the `tailscale` namespace.

**Deploy order:**

1. Create and commit `infrastructure/tailscale/operator-oauth-sealed.yaml` (ArgoCD app `platform-tailscale-secrets`, sync-wave -2)
2. Push operator (`platform-tailscale-operator`, sync-wave -1) and Pi-hole changes (sync-wave 0)
3. Confirm operator pod is Running: `kubectl -n tailscale get pods`

---

## Step 5 — Verify Pi-hole on the tailnet

After ArgoCD syncs `platform-tailscale-operator` and `platform-pihole`:

1. **Machines** in Tailscale admin → look for **`pihole-dns`** (tag `tag:k8s`).
2. Note its MagicDNS name: `pihole-dns.<your-tailnet>.ts.net`.

From a machine already on the tailnet (or after Step 6):

```bash
dig @pihole-dns.<your-tailnet>.ts.net cloudflare.com +short
dig @pihole-dns.<your-tailnet>.ts.net doubleclick.net +short   # expect 0.0.0.0 if blocked
```

---

## Step 6 — Tailscale admin DNS (global Pi-hole)

In **DNS** settings:

| Setting | Value |
|---|---|
| MagicDNS | **On** |
| Nameservers → Add custom | `pihole-dns.<your-tailnet>.ts.net` (or its `100.x.x.x` IP) |
| Fallback nameserver (recommended) | `1.1.1.1` |
| **Override local DNS** | **On** |

Save. All tailnet devices with “use Tailscale DNS” will query Pi-hole for every domain.

---

## Step 7 — MacBook

1. Install [Tailscale for macOS](https://tailscale.com/download/mac).
2. Log in to your tailnet.
3. Menu bar → Tailscale → ensure you are connected.
4. **Use Tailscale DNS** should be on by default when Override local DNS is enabled in admin. If not: **Preferences → DNS → Use Tailscale DNS**.

**Verify:**

```bash
scutil --dns | head -30
# Should show Tailscale / Pi-hole related resolvers when connected

dig doubleclick.net +short
# 0.0.0.0 when Pi-hole blocks it
```

Check Pi-hole (via `https://pihole.artr.com.br` + TinyAuth) → Query Log → client should be your Mac’s `100.x` address.

---

## Step 8 — Android

1. Install [Tailscale from Google Play](https://play.google.com/store/apps/details?id=com.tailscale.ipn).
2. Log in and connect to the tailnet.
3. In the Tailscale app: **⋮ → Use Tailscale DNS** → **On**.

**Important — disable Android Private DNS** (conflicts with Tailscale DNS):

- **Settings → Network & internet → Private DNS** → **Off** (or “Automatic”, not a custom hostname like `pihole.artr.com.br`).

**Verify:**

- Open Chrome → visit a site; check Pi-hole Query Log for your phone’s `100.x` IP.
- If pages fail to load: confirm Private DNS is off and Tailscale DNS is on ([known Android issue](https://github.com/tailscale/tailscale/issues/18003)).

---

## Step 9 — “Always on” behavior

With **Override local DNS** enabled:

- On **Wi‑Fi at home** and **mobile data**, DNS goes through Pi-hole whenever Tailscale is connected.
- Enable **Start on login** (Mac) and allow Tailscale **battery unrestricted** (Android) so the VPN stays up in the background.
- When Tailscale is **disconnected**, devices fall back to local/ISP DNS (no Pi-hole).

Optional: Mac **Login Items** / Android **Always-on VPN** (device settings) if you want Tailscale to reconnect aggressively.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| No `pihole-dns` machine | Operator logs: `kubectl -n tailscale logs -l app=operator`; OAuth Secret keys must be `client_id` / `client_secret` |
| `dig @pihole-dns...` timeout | Pi-hole pod: `kubectl -n platform get pods -l app=pihole`; FTL listening mode `all` in values |
| Mac works, Android doesn’t | Turn off **Private DNS**; update Tailscale app |
| Public home DNS broke | Traefik NLB path is separate; check `apps/platform/pihole/README.md` NLB section |
| DNS works but no ad block | Confirm global nameserver is Pi-hole, not fallback only |

---

## Related files

| Path | Purpose |
|---|---|
| `argocd/applications/platform/platform-tailscale-secrets.yaml` | OAuth SealedSecret (sync-wave -2) |
| `argocd/applications/platform/platform-tailscale-operator.yaml` | Operator Helm via ArgoCD |
| `charts/tailscale-operator-values.yaml` | Operator Helm values |
| `charts/pihole-values.yaml` | Tailnet expose annotations + `listeningMode=all` |
| `apps/platform/pihole/README.md` | Public NLB / Traefik DNS |
