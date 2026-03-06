# Platform storage (NFS stack)

## If ArgoCD shows "In Progress" and you see no logs

Sync order: PV → PVC → Deployment → Service → NFS PV → NFS PVC. A stuck sync usually means a resource is not becoming Ready (e.g. PVC Pending, Pod Pending).

**1. See what ArgoCD is doing**
```bash
# Application sync status and events
kubectl get application platform-storage -n argocd -o yaml

# Or in ArgoCD UI: click platform-storage → "App details" / "Sync" tab for sync logs
```

**2. Check resources in platform namespace**
```bash
kubectl get pv,pvc,pod,deploy,svc -n platform
```

**3. If PVC is Pending**
- Block PVC needs the PV `shared-50g-block` to exist and be **Available**. Check: `kubectl get pv shared-50g-block`.
- If PV is **Released** (was bound, then claim deleted), it won't rebind. Clear it: `kubectl patch pv shared-50g-block -p '{"spec":{"claimRef": null}}'`. Then the PVC should bind.
- If PV is missing or has wrong `volumeHandle`, run `./scripts/update-storage-pv-from-terraform.sh` and re-apply/commit.

**4. If nfs-server pod exists but is Pending or Init**
```bash
kubectl describe pod -n platform -l app=nfs-server
kubectl logs -n platform -l app=nfs-server -c create-dirs --all-containers=true
kubectl logs -n platform -l app=nfs-server -c nfs-server --all-containers=true
```

**5. Pod logs once running**
```bash
kubectl logs -n platform -l app=nfs-server -f
```
