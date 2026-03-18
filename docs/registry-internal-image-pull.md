# Pull images from the in-cluster registry (no egress to public `docker.artr.com.br`)

Kubelet pulls on **worker nodes**. They cannot resolve `*.svc.cluster.local`. They **can** reach the registry Service **ClusterIP** (kube-proxy sends traffic to the registry pod).

## 1. Pin a stable ClusterIP on the registry Service

Pick an unused IP in your cluster **Service CIDR** (`kubectl cluster-info dump | grep service-cluster-ip-range` or your cloud docs). If `10.96.240.50` is outside that range or already taken, pick another and keep registry + app image in sync.

In `charts/docker-registry-values.yaml` set:

```yaml
service:
  clusterIP: 10.96.240.50   # must be free; change if Helm fails
```

Sync the chart. If the Service already exists **without** that IP, you may need to delete the Service once (brief registry disruption) so Helm can recreate it with the fixed IP.

Confirm:

```bash
kubectl get svc docker-registry -n platform -o wide
```

Use **that same IP** in app image references: `10.96.240.50:5000/repo/image:tag`.

## 2. Tell containerd to use HTTP for that registry (every worker node)

The registry listens on **plain HTTP** on port 5000 inside the cluster. Containerd defaults to HTTPS → pulls fail until you add a mirror.

On **each node** (adjust path for your OS; OKE often uses `/etc/containerd/config.toml` or a drop-in):

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."10.96.240.50:5000"]
      endpoint = ["http://10.96.240.50:5000"]
```

Then:

```bash
sudo systemctl restart containerd
```

Repeat on **every** node that can run workload pods that pull from this registry.

## 3. Pull secret (registry still has auth)

**Plain Secret (quick test):**

```bash
kubectl create secret docker-registry docker-registry-pull \
  -n sitio-staging \
  --docker-server=10.96.240.50:5000 \
  --docker-username='YOUR_USER' \
  --docker-password='YOUR_PASSWORD' \
  --docker-email='unused@example.com'
```

**GitOps (SealedSecret):** from repo root, see  
`apps/sitio-staging/sitio-wix-webhooks/README.md` — same `--docker-server` as above, then pipe to `kubeseal` into `docker-registry-pull-sealed.yaml`.

## 4. App `image` field

Use:

`10.96.240.50:5000/sitio-wix-webhooks-microservice:sha-15335bd`

(not `docker.artr.com.br`, not `*.svc.cluster.local`).

---

**Alternative (VPC-only, no ClusterIP on nodes):** put an **internal** load balancer in front of the registry and use a private DNS name that resolves only inside your VCN. Same idea: nodes must resolve the name and reach the registry without going to the public internet.
