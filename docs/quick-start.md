# Quick Start

## 1) Install Argo CD

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## 2) Get the initial admin password

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

## 3) Port-forward the Argo CD API server

```sh
kubectl port-forward -n argocd svc/argocd-server 8080:80
```

## 4) Configure repo and change password

- Open `http://localhost:8080` and log in with user `admin`.
- Add the Git repo in Argo CD (Settings > Repositories).
- Change the admin password (User Info > Update Password).

