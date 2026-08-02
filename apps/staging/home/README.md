# home

Personal portfolio app on OCIR.

| Env | Namespace | URL |
|-----|-----------|-----|
| Staging | `staging` | https://home-staging.artr.com.br |
| Production | `production` | https://artr.com.br |

Image: `vcp.ocir.io/axtvnrdemzo7/home:<tag>`

**CI:** push to `main` in `artieeez/home` builds/pushes and bumps the staging image tag. Promote staging → production with the `Promote home to production` workflow in this repo (`workflow_dispatch`).

SealedSecrets (`ocir-pull`, `home-secrets`, `home-kb-git`) are sealed for both namespaces.

`home-secrets` keys:

| Key | Purpose |
|-----|---------|
| `RAILS_MASTER_KEY` | Rails credentials / production secrets |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Active Record Encryption (Admin DeepSeek key, etc.) |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Active Record Encryption |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Active Record Encryption |

Staging and production use **different** encryption key sets. Rotating them invalidates ciphertext already stored in SQLite (re-set Admin DeepSeek key after rotate).

## Knowledge Base (git-sync)

Private repo: [`artieeez/home-knowledge`](https://github.com/artieeez/home-knowledge) (read-only deploy key in `home-kb-git`).

The `home` pod runs a **git-sync** sidecar that clones/pulls that repo into an `emptyDir` and exposes it at `/rails/knowledge/current` (`KNOWLEDGE_BASE_PATH`). Push to `main` on the KB repo; the sidecar polls about every 60s. Rails never holds git credentials.

After each sync, an exechook writes `/rails/knowledge/synced.json` (`KNOWLEDGE_BASE_SYNC_STATUS_PATH`) with `sha`, `short_sha`, `subject`, and `synced_at` for the future Admin status page.
