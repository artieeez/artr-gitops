# Tailscale + Pi-hole Tasks

**Spec**: `.specs/features/tailscale-pihole/spec.md`  
**Design**: `.specs/features/tailscale-pihole/design.md`

| ID | Task | Depends | Status |
|---|---|---|---|
| T1 | Add `tailscale` namespace | — | Done |
| T2 | Add operator Helm values + ArgoCD Application (sync-wave -1) | T1 | Done |
| T3 | Patch `pihole-values.yaml` (expose + listeningMode) | — | Done |
| T4 | Write `docs/tailscale-pihole-setup.md` (OAuth, ACL, DNS admin, Mac, Android) | T2, T3 | Done |
| T5 | Update `apps/platform/pihole/README.md` with tailnet section | T3 | Done |

---

## T1: Add `tailscale` namespace

**What**: Add Namespace manifest for operator.  
**Where**: `infrastructure/namespaces/namespaces.yaml`  
**Done when**: Namespace listed alongside `platform`, `monitoring`.

---

## T2: Tailscale operator ArgoCD app

**What**: Helm chart from `https://pkgs.tailscale.com/helmcharts`, values in `charts/tailscale-operator-values.yaml`. OAuth via pre-created `operator-oauth` Secret (documented, not committed in plaintext).  
**Where**: `argocd/applications/platform/platform-tailscale-operator.yaml`  
**Done when**: Application renders; sync-wave `-1` on Application metadata.

---

## T3: Pi-hole tailnet expose

**What**: Annotate `serviceDns` and set `FTLCONF_dns_listeningMode=all`.  
**Where**: `charts/pihole-values.yaml`  
**Done when**: Values include `tailscale.com/expose` and `tailscale.com/hostname: pihole-dns`.

---

## T4: Setup runbook

**What**: End-to-end guide: tailnet account, ACL, OAuth + SealedSecret, deploy order, admin DNS, Mac, Android, verification.  
**Where**: `docs/tailscale-pihole-setup.md`  
**Done when**: Operator can bootstrap without reading Tailscale source.

---

## T5: Pi-hole README

**What**: Short pointer to runbook + architecture note (public NLB unchanged).  
**Where**: `apps/platform/pihole/README.md`  
**Done when**: README mentions tailnet DNS path.
