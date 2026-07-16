# OpenShift OLM Field Guide for Disconnected Environments

**Last updated:** 2026-07-16 · **Document version:** 2.0

This guide is for Red Hat consultants and customer platform teams who need to mirror and upgrade OLM-based operators in disconnected or air-gapped OpenShift environments.

Disconnected operator upgrades are harder than they should be. Every mirror run has real cost - time, bandwidth, media handling, security review, and change windows - and a failed or oversized run means repeating the entire transfer cycle. There is no room for trial and error.

The official documentation covers supported commands and schemas, but leaves critical decisions to the reader: which bundles to actually mirror, how to compute the minimal upgrade path, and what to do when `oc-mirror` itself hits known issues like d2m catalog rebuild failures. This guide fills those gaps with practical techniques gathered from real disconnected deployments:

- Computing the minimal supported upgrade path by inspecting raw catalog metadata (`replaces`, `skipRange`)
- Building pruned catalog images for exact control over what OLM can see and install
- Working around known d2m failures with `registries.conf` redirects
- Applying generated resources in the tested order so the disconnected cluster behaves as expected

After following this guide, you will be able to compute the minimal supported upgrade path for an operator, mirror only the required content, and apply it on a disconnected cluster with a predictable outcome.

**What this guide is not:**

- A replacement for official product documentation, support policy, or release notes
- A generic Kubernetes operator tutorial
- A promise that one workflow fits every security boundary or customer process

## Guide sections

| # | Section | Description |
|---|---------|-------------|
| 1 | [Foundations](01-foundations/README.md) | Terminology, OLM installation flow, mental model, operator compatibility matrix |
| 2 | [oc-mirror](02-oc-mirror/README.md) | Setup, workflows (m2d / d2m / m2m), ImageSetConfiguration, resilient flags, delete and pinning |
| 3 | [Pruned catalog images](03-pruned-catalogs/README.md) | Building custom catalog images with exact control over bundled content |
| 4 | [Upgrade path](04-upgrade-path/README.md) | Computing the minimal upgrade path with `opm render`, `skipRange`, and the path solver script |
| 5 | [Cluster-side apply](05-cluster-apply/README.md) | Apply order, catalog retagging, Subscription patching after mirroring |
| 6 | [Troubleshooting](06-troubleshooting/README.md) | d2m catalog resolution failures and `registries.conf` workaround |
| 7 | [References](07-references/README.md) | Official docs, tools, labs, and knowledge base articles |

## Included scripts and files

| File | Location | Description |
|------|----------|-------------|
| `resolve-operator-path.sh` | [`04-upgrade-path/`](04-upgrade-path/resolve-operator-path.sh) | Computes the minimal upgrade path from catalog metadata and generates an ISC snippet |
| `prune-catalog.sh` | [`03-pruned-catalogs/`](03-pruned-catalogs/prune-catalog.sh) | Wraps the jq filter for pruning FBC catalogs to specific packages/channels/bundles |
| `Dockerfile` | [`03-pruned-catalogs/`](03-pruned-catalogs/Dockerfile) | Builds a pruned catalog image from filtered FBC data |
| `registries.conf` | [`06-troubleshooting/`](06-troubleshooting/registries.conf) | Registry redirect for the d2m workaround |
