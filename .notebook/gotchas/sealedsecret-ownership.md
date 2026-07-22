# SealedSecret ownership conflict

## Symptom
ArgoCD app Degraded/OutOfSync; sync fails with:
`Resource "<name>" already exists and is not managed by SealedSecret`

## Cause
A plain Secret was created before the SealedSecret. Controller refuses to adopt it → SealedSecret `Synced=False` → Argo health Degraded. Failed sync also blocks prune of other orphans.

## Fix (cluster)
1. `kubectl delete secret <name> -n <ns>` (or delete+reapply SealedSecret if status stuck)
2. Confirm Secret has `ownerReferences` → SealedSecret and status Synced=True
3. Manual Argo sync with prune (auto-sync may stay Failed after 5 retries)

## Seen
`staging/postgres-staging-auth` — Jul 2026. Password unchanged after recreate (`MTIzNDU2Nzg=`). Orphan `IngressRouteTCP/postgres-staging` pruned once sync succeeded.
