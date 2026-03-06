# FileBrowser (Quantum)

**URL:** https://quantum.artr.com.br

## First login

Per [FileBrowser Quantum docs](https://filebrowserquantum.com/en/docs/configuration/authentication/password/), the default admin user is `admin`. Set its password via the `FILEBROWSER_ADMIN_PASSWORD` env (recommended).

Create the secret, then restart the pod:

```bash
kubectl create secret generic filebrowser-admin -n platform --from-literal=password=YOUR_SECURE_PASSWORD
kubectl rollout restart deployment/filebrowser -n platform
```

- **Username:** `admin`
- **Password:** the value you set in the secret

If you don’t create the secret, the app may use a default or prompt you on first access; set the secret for a known admin password.
