#!/usr/bin/env bash
set -Eeuo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.37.1}"
KUBERNETES_MINOR_VERSION="${KUBERNETES_MINOR_VERSION:-${KUBERNETES_VERSION%.*}}"
KUBERNETES_IMAGE_REPOSITORY="${KUBERNETES_IMAGE_REPOSITORY:-registry.aliyuncs.com/google_containers}"
CALICO_VERSION="${CALICO_VERSION:-v3.33.0}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-jammy}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KUBE_PACKAGE_DIR="$ROOT_DIR/roles/kubernetes_packages/files/packages"
RUNTIME_PACKAGE_DIR="$ROOT_DIR/roles/container_runtime/files/packages"
IMAGE_DIR="$ROOT_DIR/roles/container_runtime/files/images"
CALICO_FILE="$ROOT_DIR/roles/calico/files/calico.yaml"
WORK_DIR="$(mktemp -d)"
chmod 0755 "$WORK_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command_name in apt-get curl dpkg-deb gpg ctr sudo; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'ERROR: %s is required.\n' "$command_name" >&2
        exit 1
    }
done

mkdir -p "$KUBE_PACKAGE_DIR" "$RUNTIME_PACKAGE_DIR" "$IMAGE_DIR" "$(dirname "$CALICO_FILE")"
mkdir -p "$KUBE_PACKAGE_DIR/partial" "$RUNTIME_PACKAGE_DIR/partial"
rm -f "$KUBE_PACKAGE_DIR"/*.deb "$RUNTIME_PACKAGE_DIR"/*.deb "$IMAGE_DIR"/*.tar

KUBE_KEY="$WORK_DIR/kubernetes.gpg"
curl --fail --location --silent --show-error \
    "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR_VERSION}/deb/Release.key" |
    gpg --dearmor > "$KUBE_KEY"
chmod 0644 "$KUBE_KEY"

SOURCE_DIR="$WORK_DIR/sources.list.d"
mkdir -p "$SOURCE_DIR" "$WORK_DIR/state/lists/partial" "$WORK_DIR/cache"
touch "$WORK_DIR/state/status"

KUBE_LIST="$SOURCE_DIR/kubernetes.list"
printf 'deb [signed-by=%s] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
    "$KUBE_KEY" "$KUBERNETES_MINOR_VERSION" > "$KUBE_LIST"

cat > "$SOURCE_DIR/ubuntu.list" <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $UBUNTU_MIRROR $UBUNTU_CODENAME main restricted universe multiverse
deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $UBUNTU_MIRROR $UBUNTU_CODENAME-updates main restricted universe multiverse
deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $UBUNTU_SECURITY_MIRROR $UBUNTU_CODENAME-security main restricted universe multiverse
EOF

APT_OPTIONS=(
    -o Dir::Etc::sourcelist=/dev/null
    -o "Dir::Etc::sourceparts=$SOURCE_DIR"
    -o "Dir::State=$WORK_DIR/state"
    -o "Dir::State::status=$WORK_DIR/state/status"
    -o "Dir::Cache=$WORK_DIR/cache"
    -o APT::Get::List-Cleanup=0
)

printf 'Updating isolated Ubuntu %s and Kubernetes package indexes...\n' "$UBUNTU_CODENAME"
sudo apt-get "${APT_OPTIONS[@]}" update

download_packages() {
    local destination=$1
    shift
    sudo apt-get "${APT_OPTIONS[@]}" \
        -o "Dir::Cache::archives=$destination" \
        --download-only --no-install-recommends --yes install "$@"
    sudo chown "$(id -u):$(id -g)" "$destination"/*.deb
    sudo rm -rf "$destination/lock" "$destination/partial"
}

printf 'Downloading Kubernetes packages and dependencies...\n'
download_packages "$KUBE_PACKAGE_DIR" \
    "kubelet=${KUBERNETES_VERSION}-1.1" \
    "kubeadm=${KUBERNETES_VERSION}-1.1" \
    "kubectl=${KUBERNETES_VERSION}-1.1"

printf 'Downloading containerd packages and dependencies...\n'
download_packages "$RUNTIME_PACKAGE_DIR" containerd

printf 'Downloading Calico manifest...\n'
curl --fail --location --silent --show-error \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    --output "$CALICO_FILE"

KUBEADM_DEB="$(find "$KUBE_PACKAGE_DIR" -name 'kubeadm_*.deb' -print -quit)"
dpkg-deb --extract "$KUBEADM_DEB" "$WORK_DIR/kubeadm"

mapfile -t IMAGES < <(
    "$WORK_DIR/kubeadm/usr/bin/kubeadm" config images list \
        --kubernetes-version "v$KUBERNETES_VERSION" \
        --image-repository "$KUBERNETES_IMAGE_REPOSITORY"
    awk '$1 == "image:" {gsub(/"/, "", $2); print $2}' "$CALICO_FILE" | sort -u
)

printf 'Pulling and exporting %s container images...\n' "${#IMAGES[@]}"
for image in "${IMAGES[@]}"; do
    archive_name="$(printf '%s' "$image" | sed 's#[/:]#_#g').tar"
    printf '  %s\n' "$image"
    sudo ctr --namespace k8s.io images pull "$image"
    sudo ctr --namespace k8s.io images export "$IMAGE_DIR/$archive_name" "$image"
    sudo chown "$(id -u):$(id -g)" "$IMAGE_DIR/$archive_name"
done

printf '%s\n' \
    '' \
    'Artifacts are ready. Set use_cached_artifacts: true in' \
    'inventories/production/group_vars/all/main.yml.'
