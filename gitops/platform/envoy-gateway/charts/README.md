# Vendored Envoy Gateway charts

Envoy Gateway publishes its Helm charts only as OCI artifacts on Docker Hub. They are vendored here
unchanged, so Argo CD does not depend on Docker Hub.

| Chart | Version | Digest |
|---|---|---|
| `oci://docker.io/envoyproxy/gateway-helm` | v1.9.2 | `sha256:be034275b55deeddd6b7bc1f4da6eeb02b8efc418a4a29e2b1977851b24b1e63` |
| `oci://docker.io/envoyproxy/gateway-crds-helm` | v1.9.2 | `sha256:940b88fe361cb22fb651e3075f649e9be885f35b1c8a990658c1a2acc2d2a678` |

Update:

```bash
cd gitops/platform/envoy-gateway/charts
rm -r gateway-helm gateway-crds-helm
helm pull oci://docker.io/envoyproxy/gateway-helm --version vX.Y.Z --untar
helm pull oci://docker.io/envoyproxy/gateway-crds-helm --version vX.Y.Z --untar
```
