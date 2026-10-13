# Ansible Kubeadm Calico

This project creates a Kubernetes cluster on Debian or Ubuntu hosts with one
control-plane node and any number of workers. It provides:

- Linux preparation for Kubernetes networking and swap requirements;
- containerd configured with systemd cgroups;
- pinned Kubernetes minor or package versions;
- idempotent `kubeadm` control-plane initialization and worker joins;
- Calico networking installed after all workers join;
- online deployment or role-local package, manifest, and image caches;
- post-deployment node readiness verification.

The roles are modular, configurable, and idempotent. The design follows the
same operational conventions as the `ansible-redis-sentinel-ha` project:
environment-scoped inventory, role defaults, argument validation, component
switches, tags, lint configuration, and CI syntax checks.

## Architecture

```text
control-1   kube-apiserver + controller-manager + scheduler + etcd
worker-1    kubelet + containerd
worker-N    kubelet + containerd

All nodes   Calico node agent
Cluster     Calico kube-controllers
```

The project intentionally supports exactly one control-plane node. It is not a
high-availability control-plane design.

## Project layout

```text
inventories/production/hosts.yml               Node addresses and groups
inventories/production/group_vars/all/main.yml Deployment configuration
roles/                                         Modular Ansible roles
library/kube.py                                Local kubectl-backed module
site.yml                                       Main deployment playbook
download-artifacts.sh                          Offline cache builder
create-vm.sh                                   Optional libvirt VM creator
```

The roles manage node preparation, containerd, Kubernetes packages, kubeadm,
worker joins, Calico, and final cluster validation.

## Requirements

- An Ansible controller with Python 3 and `ansible-core` 2.16 or newer.
- Debian 12 or Ubuntu 22.04/24.04 nodes with unique hostnames.
- SSH key access and passwordless `sudo` for `ansible_user`.
- At least 2 CPU cores and 2 GiB of RAM per node.
- Full IP connectivity and consistent time between all nodes.
- Linux kernel 5.10 or newer.

Install the required Ansible collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

Allow TCP 6443, 2379-2380, 10250, 10257, and 10259 on the control plane, and
TCP 10250 and 10256 on workers. The default Calico IP-in-IP configuration also
requires IP protocol 4 between nodes.

## Configure the deployment

Set host addresses only in `inventories/production/hosts.yml`:

```yaml
control_plane:
  hosts:
    control-1:
      ansible_host: 192.168.122.64
workers:
  hosts:
    worker-1:
      ansible_host: 192.168.122.141
```

Set the SSH user, component switches, versions, paths, networks, and timeouts in
`inventories/production/group_vars/all/main.yml`. Every component has an enable
variable:

```yaml
kubernetes_node_preparation_enabled: true
container_runtime_enabled: true
kubernetes_packages_enabled: true
kubernetes_control_plane_enabled: true
kubernetes_workers_enabled: true
calico_enabled: true
kubernetes_validation_enabled: true
```

The default pod network is `192.168.0.0/16`, matching the standard Calico
manifest. Change the manifest configuration as well if this CIDR is changed.

## Cached and offline deployment

The project can keep packages, manifests, and container images directly under
the relevant roles. On an internet-connected Ubuntu machine with containerd
running, build the cache with:

```bash
./download-artifacts.sh
```

The cache contains:

- containerd and its required Jammy `.deb` dependencies;
- `kubelet`, `kubeadm`, `kubectl`, and their required `.deb` dependencies;
- the selected Calico manifest;
- kubeadm control-plane, etcd, CoreDNS, pause, and Calico image archives.

Artifacts are stored under:

```text
roles/container_runtime/files/packages/
roles/container_runtime/files/images/
roles/kubernetes_packages/files/packages/
roles/calico/files/calico.yaml
```

Enable offline mode in the production variables:

```yaml
use_cached_artifacts: true
```

Generated caches are intentionally excluded from Git because container image
archives exceed GitHub's normal file-size limit. Every clone can reproduce the
same role-local cache by running `./download-artifacts.sh`.

The playbook then copies packages and images from the controller, installs
packages with `dpkg`, and imports images into containerd's `k8s.io` namespace.
Repeated runs compare cached and installed versions and remain idempotent.

The downloader targets Ubuntu 22.04 (`jammy`) on `amd64` by default. Override
`UBUNTU_CODENAME`, `UBUNTU_MIRROR`, and `UBUNTU_SECURITY_MIRROR` only when the
cluster nodes use another compatible Ubuntu release.

## Validate and deploy

Confirm inventory and SSH connectivity:

```bash
ansible-inventory --graph
ansible kubernetes_cluster -m ping
```

Validate playbook syntax:

```bash
ansible-playbook site.yml --syntax-check
```

Deploy the cluster:

```bash
ansible-playbook site.yml
```

Run the same command again to confirm idempotence. The recap should report no
unexpected changes.

The deployment initializes the control plane, joins workers, installs Calico,
and waits for all nodes to become Ready. Workers can briefly show `NotReady`
before Calico is installed; this is expected.

## Common Ansible operations

List available tags and tasks:

```bash
ansible-playbook site.yml --list-tags
ansible-playbook site.yml --list-tasks
```

Run selected components after the initial full deployment:

```bash
ansible-playbook site.yml --tags preparation,runtime,packages
ansible-playbook site.yml --tags control_plane,workers
ansible-playbook site.yml --tags calico
ansible-playbook site.yml --tags verify
```

Preview changes where modules support check mode:

```bash
ansible-playbook site.yml --check --diff
```

## Cluster operations

The control-plane role installs the administrator kubeconfig for the configured
SSH user. Connect to the control plane and inspect the cluster:

```bash
kubectl get nodes -o wide
kubectl get pods --all-namespaces
```

To add workers, add them beneath the `workers` inventory group and rerun the
main playbook. Existing initialized and joined nodes are detected and preserved.

If `kubeadm init` stops after writing `admin.conf`, diagnose kubelet and static
pod failures before retrying. Reset only the affected node when rebuilding it:

```bash
sudo kubeadm reset --force
```

## Create libvirt VMs

`create-vm.sh` creates a qcow2 overlay from
`/var/lib/libvirt/images/fresh-clone.qcow2`, assigns a unique MAC address,
clears cloned machine and DHCP identities, enables the template's OpenSSH
server, injects the controller's public key, and waits for SSH readiness.

The template must already contain `openssh-server`. Create example nodes with:

```bash
./create-vm.sh control-plane cp ubuntu
./create-vm.sh worker-1 worker ubuntu
```

The VMs receive dynamic addresses from libvirt DHCP; the script prints each
address when creation succeeds.

## Important notes

- Set an exact `kubernetes_package_version`, including its Debian suffix, for
  strict package reproducibility in online mode.
- Keep `kubernetes_image_repository` consistent between cache generation and
  deployment. The configured repository is used by kubeadm and containerd.
- The project-local `kube` module wraps `kubectl`; it does not install the
  Kubernetes Python SDK on cluster nodes or the Ansible controller.
- Calico is deliberately installed after workers join, following the same
  ordering used by Kubespray-style cluster provisioning.
