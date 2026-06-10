# Cloud Infrastructure: PostgreSQL Backup Bucket

> **Status:** PROVISIONED (May 2026)
> **Audience:** GitOps/Kubernetes team consuming these values.
> **Traceability:** Satisfies BACKUP-05 and BACKUP-06 from `spec.md`.

---

## 1. Object Storage Bucket (PROVISIONED)

| Property | Value | Notes |
|---|---|---|
| **Name** | `sitio-production-backups` | |
| **Default Storage Tier** | **Archive** | All objects automatically stored in Archive tier (~$0.0014/GB/mo). Objects require ~1h restore. |
| **Region** | `sa-vinhedo-1` | Same region as OKE cluster. |
| **Namespace** | `axtvnrdemzo7` | Tenancy namespace for S3-compatible endpoint. |
| **Endpoint (S3-compatible)** | `axtvnrdemzo7.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com` | Path-style S3 API endpoint. |
| **Public Access** | Private | Accessed via Customer Secret Key from within cluster. |
| **Versioning** | Disabled | |

---

## 2. Object Lifecycle Policy (PROVISIONED)

| Field | Value |
|---|---|
| **Rule name** | `delete-old-backups` |
| **Target** | All objects |
| **Action** | Delete after 90 days |

---

## 3. Credentials (PROVISIONED)

Customer Secret Key created. Key pair held by the operator (not stored in this repo — will be sealed via kubeseal into `apps/.../s3-credentials-sealed.yaml`).

---

## 4. Environment Variables for CronJob

These are the concrete values to use in the CronJob YAML based on provisioned infrastructure:

```yaml
env:
  - name: DEFAULT_REGION
    value: "sa-vinhedo-1"
  - name: HOST_BASE
    value: "axtvnrdemzo7.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com"
  - name: HOST_BUCKET
    value: "axtvnrdemzo7.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com"
  - name: SSL_SECURE
    value: "True"
  - name: BUCKET
    value: "sitio-production-backups"
  # ACCESS_KEY_ID and SECRET_ACCESS_KEY from SealedSecret
```

---

## References

- [OCI Object Storage S3 Compatibility API](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi.htm)
- [OCI Object Storage Storage Tiers](https://docs.oracle.com/en-us/iaas/Content/Object/Concepts/understandingstoragetiers.htm)
- [kartoza/pg-backup Docker image](https://github.com/kartoza/docker-pg-backup)
