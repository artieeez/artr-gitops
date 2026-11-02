# Image Pull Policy

**Rule:** `imagePullPolicy` follows tag mutability, not workload importance.

- **Immutable tag** (`sha-<rev>`, a pinned version, or a `@sha256:` digest) → `IfNotPresent`
- **Floating tag** (`latest`, `*-latest`, a rolling major like `v5`) → `Always`, because only then does the pull-on-every-start actually fetch different bytes
- No explicit field at all means the Kubernetes default: `Always` for `latest`/untagged, `IfNotPresent` otherwise. Prefer writing the field out so the intent is visible.

**Related:** [Quick start](quick-start.md) · [Conventions](../.specs/codebase/CONVENTIONS.md)

---

## Why

`oracle-cluster` is a **single node**, so there is no "the other node already has it" case: every unnecessary pull is disk churn on the boot volume and a slower restart.

Re-pulling a pinned tag cannot produce different bytes. For an immutable tag, `Always` buys nothing over `IfNotPresent` — it only re-downloads the same digest on every pod restart while refilling the CRI-O store that `DiskPressure` evicts from.

`IfNotPresent` does **not** stop the image from being pulled, and it does not weaken auth: on a cache miss the kubelet still authenticates with the `ocir-pull` image pull secret and pulls normally. It only skips the registry round-trip when the exact tag is already in the local store.

## Scope today

All first-party OCIR images are built by app-repo GitHub Actions (`.github/workflows/build-push-ocir.yaml` in each app repo) and tagged with the **app commit short sha**, `sha-<rev>`. The gitops bump commit rewrites only the `image:` line. Promotion (`Promote home to production`, `Promote sitio-rails to production`) copies the staging sha tag verbatim into production — it never introduces a floating tag.

| Workload | Tag kind | Pull policy |
| --- | --- | --- |
| `apps/pi` (`pi-cloud`) | immutable `sha-<rev>` | `IfNotPresent` |
| `apps/staging/home` | immutable `sha-<rev>` | `IfNotPresent` |
| `apps/production/home` | immutable `sha-<rev>` (promoted) | `IfNotPresent` |
| `apps/sitio-staging/sitio-rails` | immutable `sha-<rev>` | `IfNotPresent` |
| `apps/sitio-production/sitio-rails` | immutable `sha-<rev>` (promoted) | `IfNotPresent` |
| `apps/games/minecraft` | `@sha256:` digest | `IfNotPresent` |

Third-party images pinned to a release tag (`git-sync:v4.7.1`, `alpine/k8s:1.37.0`, `busybox:1.38`, `pocket-id:2.16.0`, `filebrowser:1.5.5-stable`, `sealed-secrets-web:v3.1.9`) also resolve to a fixed digest and can stay `IfNotPresent`.

Floating tags that exist in the repo today, and were deliberately left alone on this sweep:

- `tinyauth:v5` — rolling major tag, `IfNotPresent`. It picks up a new patch only when the tag is not already cached (chart bump, node reboot, store prune), not on every pod restart. That is a deliberate trade against churn, not an oversight.
- `amazonlinux:2023` in the `sitio-rails-backup` CronJobs — floats within the 2023 stream, no explicit policy. Frequent short-lived pods, so `Always` would pull on every backup run; pin it if a specific patch level ever matters.

If you introduce a genuinely floating tag and you *want* it to refresh on restart, that is the one case where `Always` is correct — say why in a comment on that line.

## Operational effect

**Changes:** a pod restart, a `kubectl rollout restart`, a node reboot, an eviction, or a sync whose pod template changes without an image change all reuse the cached image instead of re-downloading it. For `pi-cloud` (2.2 GiB, the largest image in the store) that is the whole difference between a fast restart and a multi-minute pull plus ~2.2 GiB of disk traffic.

**Does not change:**

- Rollouts still roll. Any pod template edit (image tag, env, resources, annotation) still creates a new ReplicaSet — `IfNotPresent` only affects whether bytes are fetched, never whether a pod is replaced.
- Deploys still deploy. A CI bump writes a **new** `sha-<rev>`, which is a cache miss by definition, so the new image is pulled on the first pod of the new ReplicaSet. Same for `pi`, which uses `strategy: Recreate`.
- Pull auth, `imagePullSecrets`, and registry credentials are untouched.
- Nothing is reclaimed. Existing layers stay in the CRI-O store until image garbage collection or an explicit prune; this change stops the store from being refilled by re-pulls, it does not free space by itself. Growing the boot volume partition is still the fix for the partition itself.

## Caveat: a sha tag must stay write-once

`IfNotPresent` makes the local cache authoritative for a tag. If CI ever re-runs a build for the **same** commit and overwrites `sha-<rev>` with new bytes, pods will keep using the cached digest and the bump will look silently ignored. Treat `sha-<rev>` as append-only: a genuine fix is a new commit and therefore a new tag. To force a re-pull anyway, delete the pod on a fresh node or prune the image from the store.
