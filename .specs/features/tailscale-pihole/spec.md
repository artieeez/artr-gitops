# Tailscale + Pi-hole (Mac & Android) — Specification

## Problem Statement

Pi-hole runs in the OCI cluster and is reachable on the public internet via Traefik, but personal devices (MacBook, Android) are not yet on a tailnet and have no consistent ad-blocking DNS when away from home. The goal is always-on Pi-hole DNS on both devices via Tailscale, without replacing the existing public NLB path.

## Goals

- [ ] Pi-hole DNS reachable on the tailnet at a stable MagicDNS name (`pihole-dns.<tailnet>.ts.net`)
- [ ] MacBook and Android use Pi-hole for all DNS queries whenever Tailscale is running
- [ ] Cluster-side changes managed in this GitOps repo (ArgoCD)

## Out of Scope

| Item | Reason |
|---|---|
| Replacing public Traefik NLB DNS (UDP/TCP 53, DoT :853) | Keep existing home-router / public path |
| Tailscale exit node (route all internet traffic) | DNS-only requirement |
| Split DNS for `*.artr.com.br` only | User chose global Pi-hole for all queries |

---

## User Stories

### P1: Tailnet DNS endpoint ⭐ MVP

**User Story**: As an operator, I want Pi-hole exposed on my tailnet so tailnet clients can query it without relying on the public NLB.

**Acceptance Criteria**:

1. WHEN the Tailscale Kubernetes Operator is installed and synced THEN a `pihole-dns` machine SHALL appear in the Tailscale admin console with tag `tag:k8s`
2. WHEN a tailnet client runs `dig @pihole-dns.<tailnet>.ts.net cloudflare.com` THEN Pi-hole SHALL return a valid A record
3. WHEN Pi-hole receives DNS from the Tailscale ingress proxy THEN it SHALL accept queries (`FTLCONF_dns_listeningMode=all`)

**Independent Test**: From any tailnet device, `dig @pihole-dns.<tailnet>.ts.net doubleclick.net` returns `0.0.0.0` (blocked).

---

### P1: Always-on client DNS ⭐ MVP

**User Story**: As a user on MacBook or Android, I want all DNS to go through Pi-hole whenever Tailscale is connected so ads are blocked everywhere.

**Acceptance Criteria**:

1. WHEN Tailscale admin DNS is configured with Pi-hole as global nameserver and **Override local DNS** enabled THEN Mac and Android SHALL send DNS via the tailnet
2. WHEN browsing on Mac with Tailscale connected THEN Pi-hole query log SHALL show the Mac's tailnet IP as client
3. WHEN browsing on Android with Tailscale DNS enabled THEN Pi-hole query log SHALL show the phone's tailnet IP as client
4. WHEN Android system **Private DNS** is enabled THEN setup docs SHALL instruct to disable it (conflicts with Tailscale DNS)

**Independent Test**: Load a known ad domain on each device; Pi-hole dashboard shows blocked query from that device.

---

### P2: Operator bootstrap docs

**User Story**: As an operator, I want a repeatable bootstrap for OAuth credentials and ACL tags so the operator can be installed without guesswork.

**Acceptance Criteria**:

1. WHEN following `docs/tailscale-pihole-setup.md` THEN operator OAuth Secret can be created via SealedSecrets (same pattern as Pocket ID)
2. WHEN ACL tags are missing THEN docs SHALL list the required `tagOwners` entries

---

## Edge Cases

- WHEN the cluster or Pi-hole pod is down THEN Tailscale admin SHOULD list a fallback public nameserver (e.g. `1.1.1.1`) so devices retain DNS
- WHEN Tailscale is disconnected on a device THEN that device falls back to local/ISP DNS (expected)
- WHEN operator syncs before OAuth Secret exists THEN ArgoCD SHALL show operator pod waiting; docs explain bootstrap order

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
|---|---|---|---|
| TSPIH-01 | P1: Tailnet DNS endpoint | Execute | Pending |
| TSPIH-02 | P1: Tailnet DNS endpoint | Execute | Pending |
| TSPIH-03 | P1: Tailnet DNS endpoint | Execute | Pending |
| TSPIH-04 | P1: Always-on client DNS | Execute | Pending |
| TSPIH-05 | P1: Always-on client DNS | Execute | Pending |
| TSPIH-06 | P1: Always-on client DNS | Execute | Pending |
| TSPIH-07 | P2: Operator bootstrap docs | Execute | Pending |

---

## Success Criteria

- [ ] `pihole-dns` resolves on tailnet; ad domains blocked from Mac and Android
- [ ] Public NLB DNS path unchanged for home router
- [ ] Bootstrap documented end-to-end in `docs/tailscale-pihole-setup.md`
