[< Back to main guide](../README.md) | [Prev: Upgrade path](../04-upgrade-path/README.md) | [Next: Troubleshooting >](../06-troubleshooting/README.md)

# Install/upgrade an existing operator with a mirrored catalog

This section is the practical "cluster-side" procedure after mirroring is complete. Before starting, confirm that:

- The d2m or m2m run completed successfully (see [Running m2d, d2m, and m2m](../02-oc-mirror/README.md#running-m2d-d2m-and-m2m))
- The generated resources are available in `working-dir/cluster-resources/`

Terms used here are defined in [Foundations](../01-foundations/README.md).

> [!CAUTION]
> If you push a later oc-mirror run to the same catalog image tag in your registry, the new catalog image replaces the previous one silently, even if the `CatalogSource` resource name is different. Always retag mirrored catalog images to a stable, unique tag before applying them on the cluster.

**Recommended operator-focused workflow:**

1. **Publish the mirrored registry configuration on the cluster** - Apply the generated `ImageDigestMirrorSet` and `ImageTagMirrorSet` resources from `working-dir/cluster-resources/`.

> [!CAUTION]
> Mirror-set changes can trigger disruptive node drains or a MachineConfig rollout, especially when existing IDMS/ITMS objects are modified or deleted. Schedule this work inside a maintenance window and wait for any required MCP rollout to finish before continuing.

2. **Retag the mirrored catalog image and create a dedicated catalog resource** - Give each mirrored catalog image a new, stable tag in your registry (for example by date, run number, or operator scope). Create or update a dedicated `CatalogSource` or `ClusterCatalog` that points `spec.image` at that exact retagged image, with a unique resource name.

   Example with `podman`:

```bash
podman pull registry.example.com:5000/redhat/redhat-operator-index:v4.16
podman tag \
  registry.example.com:5000/redhat/redhat-operator-index:v4.16 \
  registry.example.com:5000/redhat/redhat-operator-index:acm-mce-gitops-2026-03-15
podman push registry.example.com:5000/redhat/redhat-operator-index:acm-mce-gitops-2026-03-15
```

   Example mirrored catalog object after retagging:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators-acm-mce-gitops-2026-03-15
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: registry.example.com:5000/redhat/redhat-operator-index:acm-mce-gitops-2026-03-15
  displayName: Red Hat Operators (ACM/MCE/GitOps 2026-03-15)
  publisher: Red Hat
```

3. **Use the new catalog explicitly in the operator `Subscription`** - If the operator is currently subscribed to an older mirrored catalog, patch the `Subscription` so it points to the new `CatalogSource` first. Then set the supported target channel and keep `installPlanApproval: Manual`. If the `Subscription` still points to the previous catalog, OLM will continue resolving from that older catalog and the new bundles will not be used.

```bash
oc -n <operator-namespace> patch subscription <subscription-name> \
  --type merge \
  --patch '{"spec":{
    "source":"redhat-operators-mirrored-2026-03-15",
    "sourceNamespace":"openshift-marketplace",
    "channel":"<supported-channel>",
    "installPlanApproval":"Manual"
  }}'
```

4. **If needed, force the initial target** - To control which bundle OLM selects first, set `startingCSV` in the `Subscription` spec (see [Subscription](../01-foundations/README.md#subscription) for context):

```bash
oc -n <operator-namespace> patch subscription <subscription-name> \
  --type merge \
  --patch '{"spec":{"startingCSV":"<operator-name>.v<version>"}}'
```

5. **Approve the pending `InstallPlan` and validate the result** - Once the `Subscription` points to the correct catalog and channel, approve the `InstallPlan` if you are using manual approval, then verify the resulting `CSV` phase and operator deployment health.

```bash
oc get installplan -n <operator-namespace>
oc patch installplan <plan-name> -n <operator-namespace> \
  --type merge --patch '{"spec":{"approved":true}}'
oc get csv -n <operator-namespace>
oc get pods -n <operator-namespace>
```

6. **Keep old catalog images and catalog resources until validation is complete** - Do not delete or overwrite the previous mirrored catalog immediately. Keep the older tagged catalog image and older `CatalogSource` until the new upgrade is validated, then prune intentionally.

**Side note for platform mirroring:** If you mirrored OpenShift release payloads in the same run, also apply the generated release signature ConfigMap from `working-dir/cluster-resources/`. This is not needed for an operators-only mirror run.
