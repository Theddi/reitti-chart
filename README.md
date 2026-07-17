# reitti

Deploys [Reitti](https://github.com/dedicatedcode/reitti) (personal location
tracking & analysis) together with its supporting services, aligned with the
strict [simple-container](../simple-container) security baseline (Restricted
PSS: non-root, read-only root FS, all capabilities dropped, seccomp
RuntimeDefault).

| Component | Default | Notes |
| --- | --- | --- |
| reitti | on | main app, uid 1000, `/data` PVC (back this up) |
| [paikka](https://github.com/dedicatedcode/paikka) | on | reverse geocoder, uid 1000, `/data` + `/stats` PVCs |
| valkey | on | Redis-compatible cache/queue, stateless, `noeviction`, uid 999 |
| tile-cache | on | nginx OSM tile proxy cache, uid 101 |
| CNPG Database | on | `Database` CR on an existing CloudNativePG cluster |
| auto-import | on* | resumable Job importing OSM extracts into paikka (*needs `pbfUrls`) |
| register-geocoder | on | Job registering paikka in reitti's `geocode_services` table |
| waitFor | on | init waits: reitti → db/valkey/tile-cache, paikka → import job |

## Database (CloudNativePG + PostGIS)

Reitti needs PostgreSQL **with PostGIS**. With `cnpg.enabled` the chart creates
a declarative [`Database`](https://cloudnative-pg.io/documentation/current/declarative_database_management/)
resource in the cluster's namespace (CNPG requires that) and enables the
extension:

```yaml
cnpg:
  enabled: true
  cluster:
    name: postgres
    namespace: database
  extensions:
    - name: postgis
      version: '3.6.2'
```

Reitti's `POSTGIS_*` env vars are wired automatically to
`<cluster>-rw.<namespace>.svc.cluster.local` (override with `database.host`).

**Prerequisites this chart cannot do for you** (they belong to the cluster's
own GitOps config):

1. **PostGIS-capable image on the cluster** — declarative extensions only run
   `CREATE EXTENSION`; the libraries must exist in the image. Switch the
   cluster to `ghcr.io/cloudnative-pg/postgis:<same-major>` first (rolling
   update, no data loss; keep the same Postgres major and an equal-or-newer
   minor). Recovery clusters must then use the PostGIS image too.
2. **The role** — add to the Cluster spec:
   ```yaml
   managed:
     roles:
       - name: reitti
         ensure: present
         login: true
         passwordSecret:
           name: reitti-postgres-role   # in the cluster's namespace, labeled cnpg.io/reload=true
   ```
   and make the same password available in the release namespace as the secret
   referenced by `database.existingSecret` (e.g. via replicator).
3. CNPG **>= 1.26** for `spec.extensions` on Database resources.

Requires the CNPG CRDs; with `cnpg.enabled: false` nothing CNPG-related is
rendered and you point `database.*` at any PostGIS-enabled PostgreSQL.

## Paikka

Paikka is Reitti's reverse-geocoding engine. Reitti defaults to the hosted
public instances — after deploying, point Reitti's geocoding settings (admin
UI) at the in-cluster URL printed by `helm status`, i.e.
`http://<fullname>-paikka:80`.

Set an admin password via `paikka.admin.password` or
`paikka.admin.existingSecret`. `BASE_URL` is derived from its
httproute/ingress host when one is enabled.

> The image's entrypoint requires root (`runuser`); the chart bypasses it and
> starts the jar directly as the image's own uid-1000 user. The `prepare` /
> `import` helper scripts remain usable via `kubectl exec`.

### Auto-import (default)

Set `paikka.autoImport.pbfUrls` to one or more
[Geofabrik](https://download.geofabrik.de/) extracts (or use the `pbfUrl`
shorthand). A **Job** (`<fullname>-paikka-import-<hash>`) downloads, filters
(`osmium`) and imports them into the data PVC, while the paikka pod's
`wait-for-import` initContainer blocks until the completion marker exists — so
the app never opens its RocksDB while the job writes it, and pod restarts
during a long import cost nothing. The job is **restart-safe**: downloads
resume (`wget -c`) and already-filtered regions are skipped. It is deliberately
*not* a helm hook: under ArgoCD, post-install hooks run as PostSync (after the
app is healthy), which would deadlock against the waiting paikka pod. Changing
the URL set creates a new job (hash in the name) and triggers a re-import on
the next pod cycle (marker `/data/.helm-autoimport`).

Sizing (from the paikka README benchmarks):

| Region | peak disk during import | final dataset | import heap |
| --- | --- | --- | --- |
| Netherlands | ~5 GB | ~0.7 GB | 2g fine |
| Germany | ~21 GB | ~3.8 GB | 8–16g |
| Planet | ~300 GB | ~65 GB | 32g+ |

Adjust `paikka.persistence.data.size` (default 25Gi), `autoImport.memory`
(JVM heap, default 2g) and `autoImport.resources.limits.memory` (heap +
off-heap RocksDB headroom) to your region. First start takes minutes to hours —
watch with `kubectl logs -f deploy/<fullname>-paikka -c autoimport`.

Manual alternative (autoImport off): `kubectl exec` the `prepare` / `import`
scripts, or copy a prepared export into the data PVC.

### Geocoder registration (default)

Reitti stores geocoders in its `geocode_services` DB table (no env var exists
for custom ones; the hosted Paikka is seeded there by migration). A
post-install/post-upgrade Job waits for reitti's schema, then **upserts** the
in-cluster Paikka (`ON CONFLICT (name) DO UPDATE`) with
`paikka.registerGeocoder.priority: 0` — tried before the hosted instance
(priority 1), which remains as fallback. Disable with
`paikka.registerGeocoder.enabled: false` and configure via the admin UI
instead.

## Tile cache (optional)

`tileCache.enabled: true` deploys `dedicatedcode/reitti-tile-cache` and points
Reitti's `TILES_CACHE` at it (disabled → `TILES_CACHE=""`, Reitti fetches tiles
directly). The image's entrypoint writes its rendered nginx config to a
read-only path and listens on port 80, so the chart renders it to `/tmp` and
rewrites the listen port to 8080 instead — same strict pattern as the base
chart.

## Exposure

`reitti.httproute` / `reitti.ingress` and `paikka.httproute` / `paikka.ingress`
work exactly like in simple-container (enable one per component). Paikka only
needs to be exposed if you want its dashboard or cross-instance access —
Reitti reaches it in-cluster.
