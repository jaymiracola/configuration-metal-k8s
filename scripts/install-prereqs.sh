#!/usr/bin/env bash
# Install the controllers that MetalCluster composes into.
#
# MetalCluster emits Metal3 and Cluster API resources, and those APIs come from
# their operators rather than from this project: the apiDependencies in
# upbound.yaml only generate build-time schemas. Without these installed the XRD
# establishes fine and the composition then fails, because the types it emits do
# not exist.
#
# Assumes a management cluster whose node address is reachable by the servers it
# provisions, which is the case for a host-native cluster such as k3s. Ironic
# runs with host networking, so it binds directly on that address: the BMC can
# fetch the boot ISO and the provisioning agent can call back, with no port
# publishing and no address translation. On a containerized control plane like
# kind the node address is a bridge address the BMC cannot reach, and you have to
# publish 6180/6385 and set EXTERNAL_IP by hand.
#
# Idempotent. Safe to re-run.
set -euo pipefail

# ------------------------------------------------------------------ settings
KUBECONFIG_PATH=${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}
CTX=${CTX:-}                      # empty means the current context
HOSTS_NS=${HOSTS_NS:-metal}       # where hosts and MetalClusters live

CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.21.1}
IRSO_VERSION=${IRSO_VERSION:-v0.11.0}
IRONIC_VERSION=${IRONIC_VERSION:-release-38.0}
BMO_VERSION=${BMO_VERSION:-v0.13.3}
CAPI_VERSION=${CAPI_VERSION:-v1.14.0}
CAPM3_VERSION=${CAPM3_VERSION:-v1.13.2}
IPAM_VERSION=${IPAM_VERSION:-v1.13.0}

# Only set this if you built Metal3 images locally because upstream publishes
# none for your platform (e.g. IMAGE_SUFFIX=-arm64). Empty uses upstream images.
IMAGE_SUFFIX=${IMAGE_SUFFIX:-}

# clusterctl is fetched here if absent. No root needed.
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}

# The node image is mirrored here and served on the management network, so a
# provision does not depend on a third party streaming gigabytes without
# interruption. Default location needs no root.
NODE_IMAGE_URL=${NODE_IMAGE_URL:-https://artifactory.nordix.org/artifactory/metal3/images/k8s_v1.36.2/UBUNTU_24.04_NODE_IMAGE_K8S_v1.36.2.qcow2}
IMAGE_DIR=${IMAGE_DIR:-$HOME/metal-images}
IMAGE_PORT=${IMAGE_PORT:-8080}

IRONIC_NS=baremetal-operator-system
IRONIC_CREDS=ironic-credentials

[ -r "$KUBECONFIG_PATH" ] && export KUBECONFIG="$KUBECONFIG_PATH"

k() {
  if [ -n "$CTX" ]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi
}
say() { printf '\n== %s\n' "$1"; }


# Sort tools out up front. clusterctl is not needed until the last step, so a
# missing binary would otherwise surface only after Ironic is already installed.
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }

# clusterctl renders the provider manifests, which ship with shell-style
# ${VAR:=default} placeholders that kubectl does not expand and envsubst gets
# wrong. It is a single static binary, so fetch it rather than make it a
# prerequisite.
ensure_clusterctl() {
  command -v clusterctl >/dev/null 2>&1 && return 0
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "no clusterctl build for $(uname -m); install it manually" >&2; return 1 ;;
  esac
  echo "   fetching clusterctl ${CAPI_VERSION} into ${BIN_DIR}"
  mkdir -p "$BIN_DIR"
  curl -fsSLo "$BIN_DIR/clusterctl" \
    "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VERSION}/clusterctl-${os}-${arch}"
  chmod +x "$BIN_DIR/clusterctl"
  export PATH="$BIN_DIR:$PATH"
  command -v clusterctl >/dev/null 2>&1
}
say "tools"
ensure_clusterctl || exit 1
echo "   clusterctl $(clusterctl version -o short 2>/dev/null)"

k cluster-info >/dev/null 2>&1 || { echo "cluster is not reachable" >&2; exit 1; }

# ---------------------------------------------------------------- the address
# One address, taken from what the cluster itself reports. On a host-native
# cluster this is the LAN address, so it serves for both jobs: what Ironic
# advertises to the BMC and the agent, and where Ironic fetches its own ramdisk.
#
# Override EXTERNAL_IP if the node address is not what the servers can reach,
# which is the case on a containerized control plane.
NODE_ADDRESS=$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
EXTERNAL_IP=${EXTERNAL_IP:-$NODE_ADDRESS}

[ -n "$EXTERNAL_IP" ] || { echo "could not determine the node address; set EXTERNAL_IP" >&2; exit 1; }

cat <<EOF

  cluster    $(k config current-context 2>/dev/null)
  address    $EXTERNAL_IP   advertised to the BMC, and used for Ironic's own fetches
  images     ${IMAGE_SUFFIX:-upstream}
EOF

# ------------------------------------------------------------- cert-manager
# IrSO and BMO both use webhooks, so this is first and has to be ready.
say "cert-manager $CERT_MANAGER_VERSION"
k apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
k -n cert-manager wait --for=condition=Available --timeout=300s \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# --------------------------------------------------------------- namespaces
say "namespaces"
for ns in "$IRONIC_NS" "$HOSTS_NS"; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f -
done

# -------------------------------------------------------- ironic credentials
# Ironic's API is behind basic auth. IrSO will generate a Secret with a random
# name if you let it, but BMO's basic-auth component looks for one called
# exactly "ironic-credentials", so both sides are pointed at this one. Get this
# wrong and BMO reports "provisioner is not ready" while /v1/drivers returns
# zero drivers, which looks like a driver problem instead of a 401.
say "ironic credentials"
if k -n "$IRONIC_NS" get secret "$IRONIC_CREDS" >/dev/null 2>&1; then
  echo "   already exists, keeping it"
else
  PW=${IRONIC_PASSWORD:-$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)}
  k -n "$IRONIC_NS" create secret generic "$IRONIC_CREDS" \
    --from-literal=username=ironic --from-literal=password="$PW"
  unset PW
fi

# IrSO refuses to read a credentials Secret without this label, and reports it
# as "DeploymentFailed: cannot load secret", not as a validation error.
k -n "$IRONIC_NS" label secret "$IRONIC_CREDS" \
  environment.metal3.io/ironic-standalone-operator=true --overwrite

# ------------------------------------------------------------ ironic via IrSO
say "Ironic Standalone Operator $IRSO_VERSION"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The operator's CRD must exist before the Ironic CR is accepted.
k apply -f "https://github.com/metal3-io/ironic-standalone-operator/releases/download/${IRSO_VERSION}/install.yaml"
k -n ironic-standalone-operator-system wait --for=condition=Available --timeout=300s \
  deploy/ironic-standalone-operator-controller-manager

cat > "$WORK/ironic-cr.yaml" <<EOF
apiVersion: ironic.metal3.io/v1alpha1
kind: Ironic
metadata:
  name: ironic
  namespace: ${IRONIC_NS}
spec:
  # Named so BMO can find the same Secret.
  apiCredentialsName: ${IRONIC_CREDS}
  networking:
    # No dhcp block: this is virtual media, so Ironic runs no DHCP and the
    # existing network is untouched.
    externalIP: "${EXTERNAL_IP}"
  tls:
    # BMCs generally will not trust a self-signed certificate.
    disableVirtualMediaTLS: true
  extraConfig:
    # externalIP does not cover the in-band inspection callback, which is
    # derived from [service_catalog]. Set explicitly so the URL baked into the
    # generated ISO is one the server can actually route to.
    - group: service_catalog
      name: endpoint_override
      value: http://${EXTERNAL_IP}:6385
    - group: inspector
      name: callback_endpoint_override
      value: http://${EXTERNAL_IP}:6385
    # Cleaning boots the ramdisk over virtual media, and on Dell the one-shot
    # boot override loses to an installed OS, so the first attempt boots the
    # disk and stalls until this expires. Ironic's retry then succeeds. The
    # default of 1800 spends half an hour idle before that retry; this must
    # still exceed POST plus ramdisk boot, around seven minutes here.
    - group: conductor
      name: clean_callback_timeout
      value: "900"
EOF
k apply -f "$WORK/ironic-cr.yaml"

# Pin the images. Left unset the operator picks its own default, which floats.
k -n "$IRONIC_NS" patch ironic ironic --type=merge \
  -p "{\"spec\":{\"images\":{\"ironic\":\"quay.io/metal3-io/ironic:${IRONIC_VERSION}${IMAGE_SUFFIX}\",\"deployRamdiskDownloader\":\"quay.io/metal3-io/ironic-ipa-downloader:main${IMAGE_SUFFIX}\"}}}"

echo "   waiting for Ironic to come up"
k -n "$IRONIC_NS" wait --for=condition=Ready --timeout=600s ironic/ironic

# ------------------------------------------------------ bare metal operator
say "Bare Metal Operator $BMO_VERSION"
BMO=$WORK/bmo; mkdir -p "$BMO"

# DEPLOY_KERNEL_URL and DEPLOY_RAMDISK_URL are fetched by Ironic itself to build
# the boot ISO, not by the server. On a host-native cluster that is the same
# address the BMC uses, so there is nothing to distinguish here.
cat > "$BMO/ironic.env" <<EOF
HTTP_PORT=6180
IRONIC_ENDPOINT=http://ironic.${IRONIC_NS}.svc.cluster.local/v1/
DEPLOY_KERNEL_URL=http://${EXTERNAL_IP}:6180/images/ironic-python-agent.kernel
DEPLOY_RAMDISK_URL=http://${EXTERNAL_IP}:6180/images/ironic-python-agent.initramfs
EOF

{
  cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${IRONIC_NS}
resources:
  - github.com/metal3-io/baremetal-operator/config/default?ref=${BMO_VERSION}
components:
  # Ironic's API is behind basic auth; this mounts the credentials Secret.
  - github.com/metal3-io/baremetal-operator/config/components/basic-auth?ref=${BMO_VERSION}
generatorOptions:
  disableNameSuffixHash: true
configMapGenerator:
  - name: ironic
    behavior: replace
    envs:
      - ironic.env
EOF
  # Pins the image. The ref above only pins the manifests; config/default
  # carries :latest, so without this the operator floats to whatever main
  # last published and reports no version of its own.
  cat <<EOF
images:
  - name: quay.io/metal3-io/baremetal-operator
    newTag: ${BMO_VERSION}${IMAGE_SUFFIX}
EOF
  if [ -n "$IMAGE_SUFFIX" ]; then
    cat <<EOF
patches:
  - target:
      kind: Deployment
      name: baremetal-operator-controller-manager
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: IfNotPresent
EOF
  fi
} > "$BMO/kustomization.yaml"

# Server-side apply: the BMO CRDs are large enough to blow the annotation limit
# that client-side apply uses.
k kustomize "$BMO" | k apply --server-side --force-conflicts -f -
k -n "$IRONIC_NS" wait --for=condition=Available --timeout=300s \
  deploy/baremetal-operator-controller-manager

# ---------------------------------------------------------------- cluster api
# ------------------------------------------------------------- node images
say "node image mirror"

IMAGE_NAME=$(basename "$NODE_IMAGE_URL")
mkdir -p "$IMAGE_DIR"

# Artifactory publishes the digest as a header, so there is no checksum to
# hardcode and go stale. The upstream image is republished periodically, which
# silently invalidates a pinned value.
WANT_SHA=$(curl -sI --max-time 60 "$NODE_IMAGE_URL" \
  | awk -F': *' 'tolower($1)=="x-checksum-sha256"{print $2}' | tr -d '\r')

have_sha() {
  [ -f "$IMAGE_DIR/$IMAGE_NAME" ] || return 1
  sha256sum "$IMAGE_DIR/$IMAGE_NAME" | awk '{print $1}'
}

if [ -n "$WANT_SHA" ] && [ "$(have_sha || true)" = "$WANT_SHA" ]; then
  echo "   $IMAGE_NAME already mirrored and matches upstream"
else
  echo "   fetching $IMAGE_NAME"
  # Resume and retry: this is gigabytes over the WAN and a truncated transfer
  # is what fails a deploy half an hour later.
  curl -fL --retry 20 --retry-delay 5 --retry-all-errors -C - \
    -o "$IMAGE_DIR/$IMAGE_NAME" "$NODE_IMAGE_URL"
  GOT_SHA=$(have_sha)
  if [ -n "$WANT_SHA" ] && [ "$GOT_SHA" != "$WANT_SHA" ]; then
    echo "   checksum mismatch: got $GOT_SHA, upstream says $WANT_SHA" >&2
    exit 1
  fi
fi

{
cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: metal-images-nginx
  namespace: ${IRONIC_NS}
data:
  nginx.conf: |
    worker_processes 1;
    error_log /dev/stderr warn;
    pid /tmp/nginx.pid;
    events { worker_connections 256; }
    http {
      access_log /dev/stdout;
      client_body_temp_path /tmp/client_body;
      proxy_temp_path       /tmp/proxy;
      fastcgi_temp_path     /tmp/fastcgi;
      uwsgi_temp_path       /tmp/uwsgi;
      scgi_temp_path        /tmp/scgi;
      sendfile on;
      server {
        listen ${IMAGE_PORT};
        root /images;
        autoindex on;
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metal-images
  namespace: ${IRONIC_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metal-images
  template:
    metadata:
      labels:
        app: metal-images
    spec:
      # The machine being provisioned fetches from here, so this has to be
      # reachable at the node's LAN address, the same as Ironic.
      hostNetwork: true
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          command: ["nginx", "-g", "daemon off;", "-c", "/etc/nginx/nginx.conf"]
          ports:
            - containerPort: ${IMAGE_PORT}
          readinessProbe:
            httpGet:
              path: /
              port: ${IMAGE_PORT}
            initialDelaySeconds: 3
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
            - name: images
              mountPath: /images
              readOnly: true
      volumes:
        - name: conf
          configMap:
            name: metal-images-nginx
        - name: images
          hostPath:
            path: ${IMAGE_DIR}
            type: Directory
EOF
} | k apply -f -

k -n "$IRONIC_NS" rollout status deploy/metal-images --timeout=180s

say "Cluster API, CAPM3 $CAPM3_VERSION, IPAM $IPAM_VERSION"
CLUSTERCTL_ARGS=(--infrastructure "metal3:${CAPM3_VERSION}" --ipam "metal3:${IPAM_VERSION}")
[ -n "$CTX" ] && CLUSTERCTL_ARGS+=(--kubeconfig-context "$CTX")

if [ -n "$IMAGE_SUFFIX" ]; then
  cat > "$WORK/clusterctl.yaml" <<EOF
images:
  infrastructure-metal3:
    tag: ${CAPM3_VERSION}${IMAGE_SUFFIX}
  ipam-metal3:
    tag: ${IPAM_VERSION}${IMAGE_SUFFIX}
EOF
  CLUSTERCTL_ARGS+=(--config "$WORK/clusterctl.yaml")
fi

if [ -n "$(k get providers -A --no-headers 2>/dev/null)" ]; then
  echo "   providers already installed, skipping clusterctl init"
else
  clusterctl init "${CLUSTERCTL_ARGS[@]}"
fi

# ---------------------------------------------------------------------- rbac
# Crossplane cannot compose Metal3 or Cluster API types without this.
RBAC="$(cd "$(dirname "$0")/.." && pwd)/apis/rbac.yaml"
if [ -f "$RBAC" ]; then
  say "Crossplane RBAC"
  k apply -f "$RBAC"
fi

# -------------------------------------------------------------------- verify
say "result"
k -n "$IRONIC_NS" get ironic ironic \
  -o custom-columns=IRONIC:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status' --no-headers
k get providers -A --no-headers 2>/dev/null | awk '{printf "  %-26s %s\n", $2, $6}'
echo
echo "  API groups the composition needs:"
for g in metal3.io ipam.metal3.io cluster.x-k8s.io \
         infrastructure.cluster.x-k8s.io controlplane.cluster.x-k8s.io; do
  printf "    %-34s %s kinds\n" "$g" \
    "$(k api-resources --api-group="$g" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
done
echo
echo "  Ironic must be reachable by the BMC. From another host on the LAN:"
echo "    curl -s http://${EXTERNAL_IP}:6385"
echo
echo "  Put these in the MetalCluster, so provisioning reads from the mirror:"
echo "    imageURL:      http://${EXTERNAL_IP}:${IMAGE_PORT}/${IMAGE_NAME}"
echo "    imageChecksum: ${WANT_SHA:-$(have_sha || echo unknown)}"
