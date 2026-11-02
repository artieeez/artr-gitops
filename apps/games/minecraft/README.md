# minecraft

Vanilla Minecraft **Java 1.7.10** server on the OCI cluster.

| Item | Value |
|------|-------|
| Address | `play.artr.com.br:25565` (matches the wildcard `*.artr.com.br` → NLB reserved IP) |
| Version | 1.7.10 vanilla (`TYPE=VANILLA`) |
| Auth | **offline mode** (`online-mode=false`), gated by a whitelist of players |
| Namespace | `games` |
| Image | `docker.io/itzg/minecraft-server:java8@sha256:70c6e30e…` |
| World | PVC `minecraft-data` (10Gi, `nfs-client`, Retain) |

## Why `java8`

Pre-1.13 servers break on JDK 9+ (`LaunchWrapper` casts the system classloader to
`java.net.URLClassLoader`, which only exists on Java 8). The `java8` tag is
multi-arch and the only correct base for 1.7.10. The digest is pinned; Renovate
tracks tag and digest together.

The reference must stay **fully qualified** (`docker.io/…`): the node's CRI-O
runs `short-name-mode = enforcing`, so a bare `itzg/minecraft-server` fails to
schedule with `ImageInspectError: … returns ambiguous list`.

## Traffic path

```text
player → NLB 204.216.137.207:25565 (listener "minecraft-tcp-25565")
       → backend set "minecraft-backendset" (TCP health check on 30565)
       → node 10.0.1.226:30565 (Service NodePort)
       → pod :25565
```

The listener, backend set, backends and the NLB ingress rule for `25565` live in
`artieeez/oracle-cluster` → `modules/oke/main.tf`
(`local.minecraft_node_port = 30565`, keep it in sync with `service.yaml`).
The nodes NSG already allows `30000-32767` from anywhere, so no extra node rule
is needed. Traefik is **not** in this path.

## Players, whitelist and ops

`online-mode=false` because the household plays from PojavLauncher **local**
profiles, which present no Mojang session (with `online-mode=true` the server
rejects them as `Invalid session`). The trade-off is that a name is just a name:
whoever connects first as `Artur` *is* `Artur`. The whitelist is therefore the
only gate — keep it populated.

`whitelist.json` and `ops.json` live in the `minecraft-playerlist` ConfigMap,
mounted read-only into `/data`. Two details matter:

- Entries use **offline UUIDs** — UUIDv3(MD5) of `OfflinePlayer:<name>` — not the
  Mojang UUIDs. Verified against this image: `whitelist list` reports both
  players and a non-whitelisted name is rejected with
  `You are not white-listed on this server!`
- The `WHITELIST`/`OPS` env vars are deliberately **not** used. itzg resolves
  names through PlayerDB/Mojang, writes the online UUIDs (which never match in
  offline mode) and aborts container startup with exit code 2 for names that do
  not resolve — e.g. `ERROR : Invalid parameter provided for 'manage-users'
  command: Could not resolve user from Playerdb: Ge`

To add a player, compute their offline UUID and add it to the ConfigMap:

```bash
python3 - <<'PY'
import hashlib, uuid
name = "Ge"
d = bytearray(hashlib.md5(b"OfflinePlayer:" + name.encode()).digest())
d[6] = (d[6] & 0x0F) | 0x30
d[8] = (d[8] & 0x3F) | 0x80
print(uuid.UUID(bytes=bytes(d)))
PY
```

Because the file is a `subPath` mount it is not updated in place — after
merging, restart the pod so the server re-reads it:

```bash
kubectl -n games rollout restart deploy/minecraft
```

Runtime `whitelist add` / `op` commands do not persist, since `/data/whitelist.json`
and `/data/ops.json` are read-only. Change the ConfigMap instead.

## Sizing (single 2 OCPU / 12 GB node)

This node is the cluster's hard ceiling: ~1.5 idle cores and roughly 2.3 GiB of
reclaimable-free memory at the time of writing.

| Knob | Value | Rationale |
|------|-------|-----------|
| `MEMORY` | `1536M` | Comfortable for ~6 players on vanilla 1.7.10 |
| CPU request | `100m` | Only ~124m of node requests were free; requests gate scheduling |
| CPU limit | `1200m` | Real usage is ~0.46 cores, so bursting is safe |
| Memory request/limit | `1800Mi` / `2300Mi` | Heap + JDK 8 metaspace/off-heap headroom |
| `VIEW_DISTANCE` | `8` | 1.7.10 chunk ticking is CPU-bound; raise only after measuring TPS |

`startupProbe` allows 15 minutes for the first world generation on 2 shared
cores, and there is deliberately **no liveness probe** — a legacy server can
stall during heavy generation without being dead.

## Ops

```bash
kubectl -n games logs deploy/minecraft -f          # server console output
kubectl -n games exec deploy/minecraft -- rcon-cli list
kubectl -n games exec deploy/minecraft -- rcon-cli whitelist list
kubectl -n games exec deploy/minecraft -- rcon-cli save-all flush
```

`rcon-cli` picks up `RCON_HOST`/`RCON_PORT`/`RCON_PASSWORD` from the pod env.
The password lives in SealedSecret `minecraft-rcon` and 25575 is never exposed
by the Service. `/data/whitelist.json` and `/data/ops.json` are read-only, so
`whitelist add` and `op` fail at runtime — edit the ConfigMap (see above).

1.7.10 quirks worth remembering: `/kill` takes **no** arguments (passing a
player name silently resets the RCON connection), and `keepInventory` defaults
to `false`.

## Known gaps

- **No backups yet.** `minecraft-data` is annotated `Prune=false,Delete=false`
  and uses the Retain `nfs-client` class, but that only protects against Argo —
  not against a bad restart or `/kill @e`. Next step if the world matters:
  RCON `save-off` → `save-all flush` → tar → upload to the existing OCI Object
  Storage S3 endpoint (same pattern as `sitio-rails-backup`).
- **Offline mode is impersonable.** Anyone reaching `play.artr.com.br:25565` and
  guessing a whitelisted name can take that identity. Moving back to
  `online-mode=true` needs real Microsoft accounts in PojavLauncher, and would
  strand player data, because offline UUIDs differ from Mojang UUIDs.
- Client must also be 1.7.10; PojavLauncher needs its **JRE 8** runtime
  component installed for that version.
