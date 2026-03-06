# Staging Postgres

Create the auth secret before the deployment can run:

```bash
kubectl create secret generic postgres-staging-auth --namespace=staging --from-literal=password=YOUR_SECURE_PASSWORD
```

Or use Sealed Secrets and apply your sealed secret manifest here.
