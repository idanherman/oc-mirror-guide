[< Back to main guide](../README.md) | [Prev: Cluster apply](../05-cluster-apply/README.md) | [Next: References >](../07-references/README.md)

# d2m troubleshooting: catalog resolution and `registries.conf`

A known class of d2m failures involves oc-mirror trying to reach the source registry (`registry.redhat.io`) during the disk-to-mirror phase, which should be fully offline. The typical error is:

```
error: collect catalog "registry.redhat.io/redhat/redhat-operator-index:v4.18":
  pinging container registry registry.redhat.io:
  dial tcp: lookup registry.redhat.io: no such host
```

## Root causes

1. **Version mismatch between m2d and d2m binaries.** The tarball's `working-dir/` metadata was written by an older oc-mirror that uses a different layout. The newer d2m binary cannot find the filtered catalog metadata and falls back to pulling from the source registry. **Fix:** use the same oc-mirror binary version for both m2d and d2m.

2. **Race condition during m2d (OCPBUGS-81712).** If the catalog tag is resolved to different digests during the collection and mirroring phases of m2d (because Red Hat updated the tag between the two calls), the tarball contains inconsistent data. **Fix:** update to the latest oc-mirror binary, which pins catalog digests at the start of m2d.

3. **Incomplete m2d run.** The tarball is missing filtered catalog metadata because m2d did not complete catalog filtering. The d2m `filterOperator` code path falls through to `EnsureCatalogInOCIFormat`, which tries `docker://registry.redhat.io/...`. **Fix:** re-run m2d to completion, or use the `registries.conf` workaround below.

## Workaround with `registries.conf`

If you have an existing tarball and cannot re-run m2d, you can redirect the failing registry call to oc-mirror's own local cache. During d2m, oc-mirror extracts the tarball into a local embedded registry at `localhost:55000` (default port). A [`registries.conf`](./registries.conf) file (included in this directory) can redirect `registry.redhat.io` to that local cache:

```toml
[[registry]]
  location = "registry.redhat.io"
  insecure = true
  [[registry.mirror]]
    location = "localhost:55000"
    insecure = true
```

Apply it via environment variable:

```bash
CONTAINERS_REGISTRIES_CONF=/path/to/registries.conf \
oc-mirror --config isc.yaml \
  --from file:///path/to/archive/ \
  docker://internal-registry:5000 \
  --v2
```

This works because the catalog image is already in the local cache (loaded from the tarball during the unarchive step). The `registries.conf` redirect makes the failing resolution call hit the local cache instead of the internet.

> [!NOTE]
> There is no `--registries-conf` CLI flag in oc-mirror v2. The `CONTAINERS_REGISTRIES_CONF` environment variable is the mechanism. If unset, the `containers/image` library checks standard paths (`/etc/containers/registries.conf`, then `$HOME/.config/containers/registries.conf`).
