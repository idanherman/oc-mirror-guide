[< Back to main guide](../README.md) | [Prev: Foundations](../01-foundations/README.md) | [Next: Pruned catalogs >](../03-pruned-catalogs/README.md)

# oc-mirror

Key terms (Operator, Package, Catalog, ImageSetConfiguration, etc.) are defined in [Foundations](../01-foundations/README.md). This section covers how to set up, configure, and run oc-mirror for disconnected mirroring workflows.

## What oc-mirror does

oc-mirror uses a single declarative **ImageSetConfiguration** file to decide what to copy. It can mirror:

- **Platform (OCP) release images and update graph** - For installing or upgrading the cluster itself in a disconnected way.
- **Operator catalogs** - Catalog images (index images) and the bundle images they reference, so OLM on the disconnected cluster can install and upgrade operators.
- **Additional images** - Arbitrary OCI images that your workloads need and that are not part of OLM.

The tool does not install or configure the cluster; it only copies images and generates manifests (e.g. `ImageDigestMirrorSet`, `ImageTagMirrorSet`, `CatalogSource`, `ClusterCatalog`, and when mirroring platform content, `UpdateService`) that you apply on the cluster so it uses your internal registry.

## Workflows: m2d, d2m, m2m

Three workflows cover different connectivity patterns:

| Workflow                   | When to use                                                    | What happens                                                                                                                                                                                     |
| -------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **m2d (mirror-to-disk)**   | You have a connected host.                                     | oc-mirror pulls images from the source (e.g. `registry.redhat.io`) and writes them as tarballs to a local directory. You then move that directory (e.g. via removable media) across the air-gap. |
| **d2m (disk-to-mirror)**   | You are on the air-gapped side with the tarballs.              | oc-mirror reads the tarballs and pushes the images to your internal registry. No internet access required.                                                                                       |
| **m2m (mirror-to-mirror)** | A host can reach both the internet and your internal registry. | oc-mirror copies directly from the source registry to your registry. No tarballs or physical transfer.                                                                                           |

**Destination prefixes:** For **m2d** the destination uses the `file://` prefix (local directory). For **d2m** and **m2m** the destination uses the `docker://` prefix (container registry).

For a full air-gap, you typically run **m2d** on a connected machine, transfer the tarballs, then run **d2m** on a host inside the secure network. If you have a bastion that can see both sides, **m2m** avoids the intermediate disk step. It can also be used for internal-to-internal promotion when the host can reach both source and destination registries with valid credentials for each.

**Internal cache registry:** Across all workflows, oc-mirror runs an **embedded container registry** on `localhost:55000` (configurable with `--port`) that acts as a local image cache. During m2d, pulled images are stored in this cache before being archived into tarballs. During d2m, the tarball is extracted into this cache, and images are pushed from it to the destination registry. This cache registry is transient - it runs only while oc-mirror is active and is not exposed outside the host. Understanding this is important for the [d2m troubleshooting workaround](../06-troubleshooting/README.md).

## Set up oc-mirror

### Obtain the binary

Download oc-mirror from the [Red Hat Hybrid Cloud Console](https://console.redhat.com/openshift/downloads): **OpenShift disconnected installation tools** → **OpenShift Client (oc) mirror plugin** → choose your OS and architecture → Download.

> [!NOTE]
> On **aarch64**, **ppc64le**, and **s390x**, oc-mirror v2 is supported only for OpenShift Container Platform 4.14 and later.

The binary is not tied to a single OCP minor version. The coupling to a specific release is in your **ImageSetConfiguration** (e.g. which catalog image tag you use, such as `redhat-operator-index:v4.18`). Use the build that your OpenShift toolchain policy expects and confirm behavior with:

```bash
oc-mirror --v2 --help
```

### Standalone vs plugin

You will see both `oc-mirror` and `oc mirror` in documentation. They use the same binary:

- **Standalone** - The executable is named `oc-mirror`. Run it by path (e.g. `./oc-mirror`). No `oc` CLI is required. Useful on a jump host used only for mirroring.
- **Plugin** - If `oc-mirror` is on your `PATH`, the OpenShift CLI (`oc`) invokes it when you run `oc mirror`. One command for both cluster operations and mirroring.

### Use v2

> [!WARNING]
> oc-mirror v1 was deprecated in OCP 4.18 and will be removed in a future release. Use **v2** for all mirroring (m2d, d2m, m2m).

- Pass `--v2` on the command line.
- Use `apiVersion: mirror.openshift.io/v2alpha1` in your ImageSetConfiguration.

Quick exploration examples:

```bash
# List available packages in a catalog
oc-mirror --v2 list operators \
  --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.18

# List channels for a package
oc-mirror --v2 list operators \
  --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.18 \
  --package=advanced-cluster-management

# List versions in a specific channel
oc-mirror --v2 list operators \
  --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.18 \
  --package=advanced-cluster-management \
  --channel=release-2.13
```

### Authentication

oc-mirror must authenticate to `registry.redhat.io` (and optionally other registries). It does **not** require Podman or Docker at runtime; it is a self-contained binary that uses the `containers/image` library. It does require a valid **auth file** in a format that library understands.

**Default auth file location:** `${XDG_RUNTIME_DIR}/containers/auth.json` (documented default for `--authfile`). The underlying `containers/image` library also falls back to `~/.docker/config.json` if the primary location is absent, but this is a library-level fallback, not a documented oc-mirror default.

If your system uses another path (e.g. `~/.config/containers/auth.json` on some Podman setups), pass `--authfile` explicitly so oc-mirror finds the file.

**How to populate the auth file:**

1. **If Podman is available:** Run `podman login registry.redhat.io`. This writes credentials to a path oc-mirror can use (or that you can point to with `--authfile`).
2. **If not:** Download your [pull secret](https://console.redhat.com/openshift/install/pull-secret) from the Red Hat Hybrid Cloud Console. The file is valid JSON with an `auths` key; save it as `auth.json` (or another path and pass `--authfile`).

Example with an explicit auth file:

```bash
oc-mirror --authfile /etc/mirror/pull-secret --config config.yaml file:///mirror-dir --v2
```

## What you need before mirroring

The following checklist summarizes prerequisites from the sections above. Confirm each item before starting a mirror run:

1. **ImageSetConfiguration** - A YAML file (e.g. `config.yaml`) that specifies what to mirror: platform channels, operator catalogs and packages/channels/versions, and any additional images. See the ImageSetConfiguration section below for how to define it.
2. **Destination** - For **m2d**: a local directory path with the `file://` prefix (e.g. `file:///mnt/usb/mirror-dir`). For **d2m** or **m2m**: a registry URL with the `docker://` prefix (e.g. `docker://registry.example.com:5000`).
3. **Credentials** - Auth file for the source registry (and for d2m/m2m, access to the destination registry as needed).

After a successful run, oc-mirror writes tarballs (m2d) and/or pushes images (d2m, m2m) and generates cluster resources (mirror sets, `CatalogSource` or `ClusterCatalog`, etc.) that you apply on the cluster so it uses the mirrored content.

## Resilient run flags

Long mirror runs can fail on slow or flaky links. Two flags improve reliability:

- **`--retry-times N`** - How many times to retry a failed image pull before giving up. The v2 README default is `2`; for production or unreliable networks, use at least `5`. The only cost is extra wait time on repeated failures.
- **`--image-timeout D`** - Per-image timeout as a Go duration (`10m`, `30m`, `1h`). Default is `10m0s`, which can be too short for large operator bundles on a slow link. Use `1h` when pulling through a throttled or unstable connection.

Example production-style m2d command:

```bash
oc-mirror \
  --config imagesetconfig.yaml \
  file:///mnt/usb/mirror-dir \
  --v2 \
  --retry-times 5 \
  --image-timeout 1h \
  --authfile /etc/mirror/auth.json
```

## Workspace vs cache

Do not confuse these two directories:

**Workspace** - The `file://` path you pass on the command line.

- For **m2d**, it holds tarballs (`mirror_*.tar`) and `working-dir/` (metadata, sequence state, cluster-resources).
- For **m2m**, it holds only metadata (no tarballs).
- Only the tarballs cross the air-gap. `working-dir/` is recreated from the tarballs when you run d2m on the other side.

**Cache** - An internal directory (default under `$HOME`; override with `--cache-dir`) where oc-mirror stores blobs and metadata for performance.

- It is separate from the workspace. Do not transfer the cache across the air-gap.
- Deleting it does not delete your tarballs; the next run will re-download what it needs.
- If local disk is full, clearing the cache is a valid recovery action.

## ImageSetConfiguration

The ImageSetConfiguration is the single YAML file that tells oc-mirror what to mirror. It can also include **Helm** repositories and local charts (see the [oc-mirror README](https://github.com/openshift/oc-mirror/blob/main/README.md) for the schema). Correct configuration keeps runs small and predictable.

**Minimal structure:**

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
      - name: stable-4.18
        minVersion: 4.18.1
        maxVersion: 4.18.1
    graph: true
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.18
      packages:
        - name: compliance-operator
          channels:
            - name: stable
              minVersion: 1.7.0
  additionalImages:
    - name: quay.io/example/my-app:latest
```

**Operators stanza (read left to right):** `catalog` → which index; `packages[].name` → which operator; `channels[].name` → which channel; `minVersion` / `maxVersion` → which versions. If you omit a level, oc-mirror chooses for you, which often leads to oversized mirrors.

**Channel names** are publisher-defined labels (e.g. `release-2.13`, `stable`, `latest`). There is no global convention. In disconnected environments, treat a channel primarily as an **upgrade-graph identifier**, not as a release-cadence promise. Prefer explicit stream channels when they exist (for example `release-2.13`, `stable-2.9`, `v1.0.x`) and avoid relying on generic aliases such as `stable` or `latest` unless the vendor documents them for your version.

**minVersion / maxVersion:**

- Omitting `maxVersion` keeps the lower bound while allowing newer z-stream content in later runs.
- Omitting both typically mirrors channel head behavior for the selected scope.
- If you set version bounds but do not name a channel, oc-mirror can use the package **default channel**, which is sometimes not the one supported for your OCP version. Always name the channel explicitly.
- If your filtered channel set excludes the upstream package default, use the package `defaultChannel` field in the ImageSetConfiguration so the filtered catalog remains internally consistent.

Validate on your exact binary with `oc-mirror --v2 --help`.

**Default channel requirement:** Every filtered catalog must have a valid `defaultChannel` for each package. If your ISC's channel list excludes the upstream package default, you **must** set `packages.defaultChannel` to one of the retained channels. Omitting it causes a hard error at filter time:

```
the default channel "<original>" was filtered out, a new default channel must be configured for this package
```

This error comes from the `catalog-filter` library that oc-mirror v2 uses internally. The behavior is deterministic:

| ISC `defaultChannel` | Catalog original in filtered set? | Result |
|----------------------|-----------------------------------|--------|
| Set to a retained channel | N/A | Override applied; original ignored |
| Omitted | Yes | Original kept; no error |
| Omitted | No (filtered out) | **Hard error** - mirror refuses to proceed |

Setting `defaultChannel` does **not** cause that channel to be mirrored. It only overrides the metadata in the filtered `olm.package` entry. The channel must also appear in the `channels` list (or `channels` must be omitted entirely to include all channels).

> [!TIP]
> Always set `defaultChannel` explicitly in the ISC when specifying channels. It costs nothing and prevents failures when the upstream catalog's default does not match your channel selection. The `resolve-operator-path.sh` script handles this automatically.

When in doubt, use `--dry-run` to validate your ImageSetConfiguration before committing to a full mirror run.

**additionalImages** - For non-operator OCI images (e.g. app base images) that must be available in the disconnected environment. Plain image copies; no OLM semantics.

> [!WARNING]
> You must use **explicit registry hostnames** for every image listed under `additionalImages` (e.g. `quay.io/org/image:tag` or `registry.redhat.io/ubi8/ubi:latest`). Otherwise oc-mirror v2 mirrors them to incorrect target paths silently.

> [!TIP]
> For advanced version-selection workflows (`skipRange`, `opm render`, and the path solver script), see [Mirror only required versions](../04-upgrade-path/README.md).

## Running m2d, d2m, and m2m

**m2d (connected):** Destination is `file:///path/to/mirror-dir`. Output includes `mirror_000001.tar` (and more for large runs) plus `working-dir/` (metadata, sequence state, cluster-resources).

**Splitting tarballs with `archiveSize`:** The ImageSetConfiguration supports an `archiveSize` field (in GiB) that tells oc-mirror to split the m2d output into multiple tarballs of approximately that size:

```yaml
archiveSize: 4
```

In practice, `archiveSize` does **not** guarantee consistent tarball sizes. By default oc-mirror uses a permissive archiver: when a single container image layer is larger than the configured limit, that layer gets its own standalone archive and oc-mirror logs a warning. The result is a mix of tarballs - some at or near the limit, some exceeding it. The `--strict-archive` flag changes this to a hard error instead, but since individual image layers cannot be split, this just makes the run fail.

If you need predictable file sizes (e.g. for security scanners, removable media, or transfer tools with file-size limits), a more reliable approach is to skip `archiveSize` entirely, let m2d produce a single large tarball, and split it yourself:

```bash
# On the connected side: split into 4 GiB chunks
split -b 4G mirror_000001.tar mirror_000001.tar.part-

# On the air-gapped side: reassemble before running d2m
cat mirror_000001.tar.part-* > mirror_000001.tar
```

This gives you exact, predictable chunk sizes that work with any transfer constraint.

Transfer **only the tarballs**; leave `working-dir/` behind. It is regenerated when you run d2m.

| What              | Transfer? |
| ----------------- | --------- |
| `mirror_*.tar`    | **Yes**   |
| `working-dir/`    | **No**    |

**d2m (air-gapped):** Copy tarballs to the host. The `--from` argument must point to the directory that *contains* the `mirror_*.tar` files (not to `working-dir/`). Then:

```bash
oc-mirror --config imagesetconfig.yaml \
  --from file:///path/to/mirror-dir \
  docker://airgapped-registry:5000 \
  --v2 --retry-times 3
```

oc-mirror reads the tarballs from that directory, recreates `working-dir/` locally, and pushes the images to the registry.

> [!IMPORTANT]
> **The `--config` flag is mandatory for d2m**, even though the ISC is embedded inside the tarball. The tarball contains both the original ISC (as `isc_{timestamp}` at the tar root) and a pinned copy (`working-dir/isc_pinned_{timestamp}.yaml`), but d2m deliberately ignores the embedded copies. The `--config` ISC drives `CollectAll`, which determines what actually gets pushed - d2m does not push everything in the archive.

**Subset push: using a smaller ISC for d2m.** You can pass a different (smaller) ISC during d2m to push only a subset of what the tarball contains. The operator collector only processes operators listed in the ISC; any operators in the archive but not in the ISC are silently skipped. This is useful when a single m2d run mirrors content for multiple clusters or environments, but each d2m run targets a specific scope.

```
m2d --config full.yaml          → tarball has 5 operators + platform images
d2m --config subset-a.yaml      → pushes only 2 of those operators
d2m --config subset-b.yaml      → pushes 3 others (same tarball, separate run)
```

The same applies to `mirror.platform`, `additionalImages`, and `helm` sections - omitting a section from the d2m ISC means that content is not pushed even if it is in the archive.

> [!CAUTION]
> Do not change the package/channel/version filters for an operator between m2d and d2m. d2m reuses pre-built catalog metadata from `working-dir/` by matching a hash of the operator's ISC entry. If the hash does not match (because you changed `minVersion`, added a channel, etc.), d2m attempts to re-filter the catalog, which can fail in a disconnected environment. The safe pattern is: start from the `isc_pinned_{timestamp}.yaml` that m2d generated (it is inside `working-dir/` after unarchive) and **remove** entries you do not need, rather than modifying filter parameters.

> [!WARNING]
> In practice, subset d2m may fail in a fully disconnected environment. When d2m processes operators from a reduced ISC, it can attempt to re-filter or re-resolve the catalog against the source registry, which is unreachable. If you hit this, the [`registries.conf` workaround](../06-troubleshooting/README.md) or [building a pruned catalog image](../03-pruned-catalogs/README.md) are more reliable alternatives for scoping what each cluster sees.

**Incremental runs:** oc-mirror tracks state. Running m2d again with the same workspace mirrors only what changed. Use `--since YYYY-MM-DD` to restrict to content newer than a date. Delete the workspace only when you need a full reseed.

> [!TIP]
> For the cluster-side apply order, catalog retagging, and `Subscription` switch logic after mirroring, see [Install/upgrade with a mirrored catalog](../05-cluster-apply/README.md).

## End-to-end operator upgrade (summary)

1. Determine the minimal mirror set (e.g. `opm render` + path solver or skipRange inspection).
2. Write the ImageSetConfiguration (catalog image for your OCP minor, package, channel from support matrix, minVersion/maxVersion as needed).
3. Run m2d with `--v2 --retry-times 5 --image-timeout 1h` (and `--authfile` if needed).
4. Transfer only `mirror_*.tar` to the air-gapped side.
5. Run d2m with `--from file:///path/to/tarballs` and `docker://your-registry`.
6. Apply cluster resources in order (see [Install/upgrade with a mirrored catalog](../05-cluster-apply/README.md)):
   - Apply `ImageDigestMirrorSet` and `ImageTagMirrorSet`.
   - Wait for Machine Config Pool (MCP) rollout to complete.
   - Apply signature `ConfigMap` (only if you mirrored release images).
   - Apply catalog and `UpdateService` manifests.
7. Update the `Subscription` (channel, source, `installPlanApproval`, `startingCSV` if desired) and approve the `InstallPlan`.

## Delete subcommand and catalog pinning

**Deleting images from the mirror registry:** oc-mirror v2 does not auto-prune. To remove images you no longer need, use the `oc-mirror delete` subcommand in two phases:

1. Run with a `DeleteImageSetConfiguration` and `--generate` to produce a delete-images YAML.
2. Run `oc-mirror delete --delete-yaml-file <path>` to remove manifests from the registry.

Only manifests are deleted; run your registry's **garbage collector** to reclaim blob storage. See the [Disconnected environments documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/disconnected_environments/#delete-mirror-registry-content) for the full procedure.

**Catalog pinning:** After m2d or m2m runs, oc-mirror can write pinned configs (`isc_pinned_{timestamp}.yaml` and `disc_pinned_{timestamp}.yaml`) in the working directory. These reference catalogs by digest for reproducible mirrors and for use with the delete flow. See the [oc-mirror README - Catalog Pinning](https://github.com/openshift/oc-mirror/blob/main/README.md).
