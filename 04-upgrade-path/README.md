[< Back to main guide](../README.md) | [Prev: Pruned catalogs](../03-pruned-catalogs/README.md) | [Next: Cluster apply >](../05-cluster-apply/README.md)

# Mirror only required versions

The practical objective is to compute the **minimal logical upgrade path** from your current version to your supported target version. That path is derived from the catalog's upgrade edges (`replaces`, `skips`, `skipRange`). Whether stock oc-mirror can represent that path *exactly* is a second question; in practice, the generated ImageSetConfiguration often uses `minVersion` to approximate the exact path with a floating channel head (meaning newer z-stream patches released after your mirror run may also be included).

> [!NOTE]
> If you hear "`skipVersion`" in conversation, read it as `skipRange` in FBC metadata. There is no `skipVersion` field.

## Render the catalog to JSON

The catalog image (e.g. `redhat-operator-index:v4.18`) contains FBC data (package definitions, channel definitions, and bundle metadata including upgrade edges) but it is not directly queryable from the command line. To inspect upgrade paths, you need to **render** the catalog to a local JSON file.

**`opm`** (Operator Package Manager) is the Operator Framework tool for building and inspecting FBC catalogs. Running `opm render` pulls the catalog image and outputs a stream of JSON objects (one per FBC entity: `olm.package`, `olm.channel`, `olm.bundle`). Channel objects include `entries` with bundle names and their `replaces` / `skipRange`; bundle objects include the bundle image reference.

> [!TIP]
> **Pruned render:** A raw `opm render` dump includes `olm.bundle` objects with base64-encoded manifests that account for over 90% of the file size (e.g. ~1.1 GB for `redhat-operator-index:v4.16`). The path solver and the manual `jq` queries in this guide only need `olm.package` and `olm.channel` objects. Pipe through `jq` to strip the rest:

```bash
opm render registry.redhat.io/redhat/redhat-operator-index:v4.18 \
  | jq -c 'if .schema == "olm.package" or .schema == "olm.channel" then . else empty end' \
  > catalog.json
```

This produces a file of ~830 KB instead of ~1.1 GB, and the path solver runs in under 2 seconds instead of 30. All examples below assume you have a `catalog.json` produced this way.

## Doing it manually (without the path solver script)

You can compute the minimal logical path and write the ImageSetConfiguration by hand:

1. **Render the catalog** using the pruned pipeline above (if you have not already).

2. **List channels for your package** (replace `PACKAGE` with e.g. `advanced-cluster-management`):

   ```bash
   jq -r 'select(.schema=="olm.channel" and .package=="PACKAGE") | .name' catalog.json
   ```

3. **List channel entries with upgrade edges** (replace `PACKAGE` and `CHANNEL`; this shows bundle name, channel, `replaces`, and `skipRange`):

   ```bash
   jq -r 'select(.schema=="olm.channel" and .package=="PACKAGE" and .name=="CHANNEL") | .entries[] | [.name, .replaces, .skipRange] | @tsv' catalog.json
   ```

4. **Decide the path** - From your current version (e.g. 2.11.4) and target version (e.g. 2.13.5), check whether the target bundle's `skipRange` includes your current version (e.g. `>=2.11.0 <2.13.5` means you can jump directly). If not, find the smallest bridge bundle that *does* connect, then repeat until you reach the installed version. Omitted intermediate minors are acceptable if the retained bundles still form a valid path through `skipRange`, `skips`, or `replaces`.

5. **Write the ImageSetConfiguration** - Add a `packages` entry with the right `channels` and `minVersion` / `maxVersion` for the path you identified. Use the support matrix to choose the supported target version first, then use the catalog metadata to determine which channel(s) contain the required bridge and target bundles. If your filtered channels do not include the upstream package default, set `packages.defaultChannel` to one of the retained channels, usually the target channel.

This is error-prone for multi-channel or long chains, so the next subsection introduces a script that automates the path computation and snippet generation.

## Using the path solver script

The **path solver script** ([`resolve-operator-path.sh`](./resolve-operator-path.sh), in this directory) automates the logic above: it reads the same `catalog.json`, finds the package and channel metadata, computes the shortest valid logical upgrade path from your current version to the target version using `replaces`, `skips`, and `skipRange`, and prints an ImageSetConfiguration snippet you can paste into your config. Requirements: **Bash 4+** and **jq**.

Before running the path solver, confirm you have completed the support matrix check described in [Operator compatibility matrix](../01-foundations/README.md#operator-compatibility-matrix) and identified a supported target version and channel for your OCP minor.

**Recommended workflow:**

1. Render the catalog using the pruned pipeline from the section above (if you have not already).

2. Run the path solver with package name, current version, target version, path to `catalog.json`, and (optionally) catalog image:

   ```bash
   ./resolve-operator-path.sh \
     advanced-cluster-management \
     2.11.4 \
     2.13.5 \
     catalog.json \
     registry.redhat.io/redhat/redhat-operator-index:v4.18
   ```

3. Use the generated ImageSetConfiguration snippet as your base. The printed path is the exact logical path; the emitted `minVersion`-only config is a deliberate approximation, as newer z-stream patches in the same channel may also be mirrored if they are released before your mirror run.
4. Keep channel choice aligned with the inspected catalog metadata and your supported target version. If you must retain multiple channels, set `packages.defaultChannel` intentionally and keep `Subscription.channel` explicit during cluster-side upgrades.
5. Mirror and publish as usual (`m2d`/`d2m` or `m2m`), then verify the required bridge and target bundles are actually present in your mirrored catalog.
