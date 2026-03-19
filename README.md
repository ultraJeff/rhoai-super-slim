# RHOAI Super Slim

A minimal, mesh-free Red Hat OpenShift AI stack that proves you can serve LLMs without Knative, Service Mesh, or GPUs.

## The Stack

| Component | Role | What it replaces |
|---|---|---|
| **KServe RawDeployment** | Model serving via standard K8s Deployment + Service | Knative Serving + Service Mesh sidecars |
| **OpenShift Route** or **Gateway API** | External traffic ingress | OSSM IngressGateway |
| **vLLM + OpenVINO** (CPU) | Inference engine | GPU-bound vLLM/TGI |
| **RHOAI Dashboard** | UI for model management | (same) |

```
                     ┌─────────────────────────────────────────┐
                     │            What We DON'T Need           │
                     │  ┌──────────┐ ┌──────────┐ ┌─────────┐ │
                     │  │  Service  │ │ Knative  │ │  GPU    │ │
                     │  │  Mesh     │ │ Serving  │ │  Nodes  │ │
                     │  └──────────┘ └──────────┘ └─────────┘ │
                     └─────────────────────────────────────────┘

  Client ──► Route ──► Service ──► vLLM-CPU Pod ──► Phi-4-mini (3.8B)
                        (ClusterIP)  (OpenVINO)
```

## Quick Start

```bash
# Ensure you're logged in to an OpenShift 4.19+ cluster with RHOAI installed
oc whoami

# Deploy with the route overlay (simplest, works on bare metal)
./scripts/deploy.sh route

# Wait for model to load (watch for 1/1 Running)
oc get pods -n super-slim-demo -w

# Test it
./scripts/test-chat.sh
```

## Three Overlays

The manifests are structured as Kustomize overlays. Pick the one that fits your cluster.

### `route` -- No mesh, no gateway (default)

The simplest option. OpenShift Route for external access. Works on any cluster, including bare metal without MetalLB.

```bash
oc apply -k manifests/overlays/route
```

**What gets deployed:**
- DataScienceCluster (KServe + Dashboard + LlamaStack only)
- Namespace, ServingRuntime, InferenceService
- OpenShift Route

**Overhead:** KServe controller only (~0.1 vCPU). Zero sidecars.

### `gateway` -- Gateway API at the edge

Replaces the Route with Gateway API. The Ingress Operator installs a lightweight OSSM v3 (istiod + Envoy) in `openshift-ingress` when the GatewayClass is created. This is NOT a full Service Mesh -- no sidecars, no `ServiceMeshControlPlane` to manage.

```bash
oc apply -k manifests/overlays/gateway
```

**Requires:** MetalLB operator (or cloud LoadBalancer) for the Gateway's external IP.

**What gets deployed:** everything in `route` plus GatewayClass, Gateway, HTTPRoute.

**Overhead:** KServe controller + istiod + 1 Envoy proxy pod. Still zero sidecars in your model pods.

### `ambient` -- Transparent pod-to-pod mTLS

Builds on `gateway` and enrolls the namespace in Istio ambient mesh. A per-node ztunnel DaemonSet encrypts pod-to-pod traffic with mTLS automatically. An optional waypoint proxy adds L7 policy (header routing, auth, rate limiting).

```bash
oc apply -k manifests/overlays/ambient
```

**Requires:** MetalLB + OSSM 3.x operator installed.

**What gets deployed:** everything in `gateway` plus ambient namespace label + waypoint proxy.

**Overhead:** ztunnel DaemonSet (~0.1 CPU + 200MB per node) + optional waypoint. Still zero sidecars.

## What's in the Box

```
manifests/
  base/
    kustomization.yaml
    dsc.yaml                    # DataScienceCluster (super slim config)
    namespace.yaml              # Demo namespace
    serving-runtime.yaml        # vLLM CPU ServingRuntime
    inference-service.yaml      # Phi-4-mini InferenceService
  overlays/
    route/
      kustomization.yaml
      route.yaml                # OpenShift Route
    gateway/
      kustomization.yaml
      gateway-class.yaml        # Triggers lightweight OSSM v3 install
      gateway.yaml              # Envoy proxy + LoadBalancer
      httproute.yaml            # Routes to model service
    ambient/
      kustomization.yaml
      namespace-patch.yaml      # Adds istio.io/dataplane-mode: ambient
      waypoint.yaml             # Optional L7 waypoint proxy
scripts/
  deploy.sh                    # ./scripts/deploy.sh [route|gateway|ambient]
  test-chat.sh                 # Smoke test the endpoint
```

## Prerequisites

- OpenShift 4.19+ cluster (tested on 4.20.14)
- RHOAI operator installed (tested with 2.25.3 / RHOAI 3.x)
- Outbound internet access (to pull model from HuggingFace and vLLM image from Docker Hub)
- No GPUs required -- runs on commodity x86_64 CPUs

### Important: vLLM CPU Image

The built-in RHOAI `vllm-cpu-runtime-template` image (`registry.redhat.io/rhoai/odh-vllm-cpu-rhel9`) only supports ppc64le and s390x architectures. For x86_64 clusters, we use the upstream `docker.io/vllm/vllm-openai-cpu:latest` image instead. See `manifests/base/serving-runtime.yaml`.

### Cluster Requirements

The model needs roughly 4 CPU and 12GB RAM. A compact 3-node cluster with 16 vCPU / 96GB RAM per node works fine.

## Demo Talk Track

### 1. "Here's what we DON'T have installed"

Show the DataScienceCluster -- almost everything is `Removed`. No Service Mesh operator, no Serverless operator, no GPU nodes.

```bash
oc get datasciencecluster default-dsc -o yaml | grep managementState
oc get csv -A | grep -iE 'servicemesh|serverless|keda'  # nothing
oc get nodes -o wide  # no GPU labels
```

### 2. "Enable KServe in one apply"

```bash
oc apply -k manifests/overlays/route

# Knative Serving stays Removed -- no sidecars, no queue-proxies
oc get pods -n redhat-ods-applications | grep kserve
```

### 3. "Deploy a model with standard Kubernetes"

```bash
# Standard K8s Deployment -- no Knative revisions, no Istio sidecars
oc get deploy -n super-slim-demo
oc get pods -n super-slim-demo  # single container, no sidecar
```

### 4. "Chat with it"

```bash
./scripts/test-chat.sh
```

### 5. "What did we save?"

| Resource | Traditional RHOAI | Super Slim |
|---|---|---|
| Istio sidecar per pod | ~0.5 vCPU + 1GB RAM | 0 |
| Knative controller + activator | ~1 vCPU + 2GB RAM | 0 |
| Service Mesh control plane | ~2 vCPU + 4GB RAM | 0 |
| GPU requirement | Yes | No |
| **Total overhead** | **~3.5 vCPU + 7GB RAM** | **~0.1 vCPU (KServe controller only)** |

## Model Choice

**Phi-4-mini (3.8B)** was chosen for the best quality-per-CPU-cycle:

- 67.3% MMLU (beats Granite 3B and Llama 3.2 3B at 61.8%)
- 3.8B parameters, ~8GB RAM footprint
- 128K context window
- ~2-5 tokens/sec on x86_64 CPU with vLLM (measured on tallgeese compact cluster)

If speed matters more, swap to **Qwen 3 0.6B** (~20-40 tok/s, 1.2GB footprint) by editing the `storageUri` in `manifests/base/inference-service.yaml`.

## Future Work

- **MetalLB manifests**: Add MetalLB operator + L2 pool to the gateway overlay
- **KEDA autoscaling**: Scale model replicas based on request queue depth, including scale-to-zero
- **Model Registry**: Register and version models through the RHOAI dashboard
- **Multiple models**: Deploy different models behind the same Gateway with traffic splitting
