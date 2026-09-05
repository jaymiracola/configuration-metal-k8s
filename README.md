# Crossplane as the control plane for metal

Crossplane is well understood as a control plane for cloud infrastructure. The
same control plane and the same API model also drive a physical server.

```bash
kubectl apply -f examples/metalcluster/r730.yaml
```

One declarative object takes a bare machine and returns a running Kubernetes
cluster.

| | Cloud | Metal |
|---|---|---|
| Requested by | an XR | an XR |
| Composed into | provider managed resources | Metal3 + Cluster API resources |
| Reconciled by | Crossplane | Crossplane |
| Actuated by | a cloud API | Ironic, over Redfish |

## Prerequisites

A management cluster with:

- **Upbound Crossplane** and **provider-helm**
- **Cluster API** with the kubeadm bootstrap and control plane providers
- **Cluster API Provider Metal3** and **Metal3 IPAM**
- **Metal3**: the Bare Metal Operator and Ironic

Plus `kubectl apply -f apis/rbac.yaml`, which lets Crossplane compose Metal3 and
Cluster API types.

A server with a BMC that speaks **Redfish with virtual media enabled** (on Dell,
an iDRAC Enterprise feature), set to **UEFI boot with Secure Boot off**, and a
disk that can be erased.

`./scripts/install-prereqs.sh` installs all of that and mirrors the node image
onto the management network. Fetching images from upstream on every provision
puts a multi-gigabyte transfer in the path of each deploy, and an image
republished upstream invalidates the checksum the `MetalCluster` pins. The
script reads the digest from the upstream header and prints the `imageURL` and
`imageChecksum` to use.

Then install the API itself:

```bash
up project run --use-current-context --skip-control-plane-check
```

On Dell, also apply `operations/`. Ironic's one-shot boot override loses to an
installed OS, so booting the ramdisk over virtual media fails once the disk
holds a bootable system. A WatchOperation reorders the boot sequence when that
happens. Remove it once the override works.

### Required prerequisite settings

Four settings have no usable default. Without them Ironic reports no drivers, or
inspection waits indefinitely.

On the `Ironic` resource:

```yaml
spec:
  # The Bare Metal Operator's basic-auth component looks for this exact name.
  # Left unset, the operator generates a random one and gets 401s, which surface
  # as "provisioner is not ready" and zero drivers.
  apiCredentialsName: ironic-credentials
  networking:
    # Must be reachable by the BMC, to fetch the boot ISO, and by the
    # provisioning agent, which calls back to it.
    externalIP: <address reachable from the server>
  tls:
    # BMCs generally will not trust a self-signed certificate.
    disableVirtualMediaTLS: true
  extraConfig:
    # externalIP does not cover the inspection callback, which is derived
    # separately and defaults to the pod's own address. Omit these and the
    # server is told to call back somewhere it cannot route.
    - group: service_catalog
      name: endpoint_override
      value: http://<same address>:6385
    - group: inspector
      name: callback_endpoint_override
      value: http://<same address>:6385
```

For the Bare Metal Operator:

```bash
IRONIC_ENDPOINT=http://ironic.baremetal-operator-system.svc.cluster.local/v1/
# Fetched by Ironic to build the boot ISO, not by the server, so these want the
# node-local address rather than the external one.
DEPLOY_KERNEL_URL=http://<ironic node address>:6180/images/ironic-python-agent.kernel
DEPLOY_RAMDISK_URL=http://<ironic node address>:6180/images/ironic-python-agent.initramfs
```

## Use

### 1. Register the machine

Hosts are inventory, registered once, and outlive the clusters built on them.
`examples/host/r730.yaml` needs three values read off the hardware.

The **boot NIC's MAC**. Some BMCs report `LinkStatus` as null even on a live port,
so use speed and state, with the machine powered on:

```bash
for n in $(curl -sk -u "$IDRAC_USER:$IDRAC_PASS" \
    https://$BMC/redfish/v1/Systems/System.Embedded.1/EthernetInterfaces \
    | jq -r '.Members[]."@odata.id"'); do
  curl -sk -u "$IDRAC_USER:$IDRAC_PASS" "https://$BMC$n" \
    | jq -r '"\(.Id)  \(.MACAddress)  \(.SpeedMbps)  \(.Status.State)"'
done
```

The **root disk's WWN**, which only exists once the host has been inspected, so
register it with no `rootDeviceHints` first and then read:

```bash
kubectl -n metal get bmh r730 -o jsonpath='{.status.hardware.storage}' | jq .
```

Pin by WWN rather than size: there may be several disks, and BMCs often expose no
volume identifiers of their own.

The **interface name** the node's OS gives that NIC also comes from inspection, and
goes in the `MetalCluster` as `host.bootInterface`.

```bash
kubectl -n metal create secret generic r730-bmc \
  --from-literal=username="$IDRAC_USER" --from-literal=password="$IDRAC_PASS"
kubectl apply -f examples/host/r730.yaml
```

### 2. Ask for a cluster

```bash
kubectl apply -f examples/metalcluster/r730.yaml
```

```yaml
spec:
  host:
    pool: r730                 # selects any registered host with this label
    bootInterface: enp130s0f1
  network:
    nodeIP: 192.168.120.70
    prefix: 24
    gateway: 192.168.120.1
    dnsServer: 192.168.120.1
    podCIDR: 10.244.0.0/16
    serviceCIDR: 10.96.0.0/12
  kubernetes:
    version: v1.36.2
    imageURL: http://<management host>:8080/UBUNTU_24.04_NODE_IMAGE_K8S_v1.36.2.qcow2
    imageChecksum: 57cee0eb...
    imageChecksumType: sha256
    imageDiskFormat: qcow2
  cni:
    ciliumVersion: 1.20.1
  gpu:
    enabled: true
    operatorVersion: v26.7.0
```

That composes an `IPPool`, a Cluster API `Cluster`, `Metal3Cluster`,
`Metal3MachineTemplate`, `Metal3DataTemplate` and `KubeadmControlPlane`, plus a
provider-helm `ProviderConfig` and `Release`. Cluster API Provider Metal3 claims a
matching host, Ironic powers it through the BMC and attaches a generated boot ISO
as virtual media, the agent writes the image, kubeadm runs, and provider-helm
installs the CNI so the node reaches `Ready` unattended.

`gpu.enabled` adds a second `Release` for the NVIDIA GPU Operator. Chart v26.7
deploys a `GPUCluster` instead of a `ClusterPolicy`, which brings the kernel
driver and the container toolkit up together with the DRA driver, so a workload
asks for a GPU through `resource.k8s.io` against the `gpu.nvidia.com`
DeviceClass rather than as an `nvidia.com/gpu` extended resource. The two CRs
are mutually exclusive and only the `GPUCluster` path publishes a DeviceClass.
Set `gpu.driverVersion` to pin the driver; left unset it follows the chart.

The driver module is compiled against the running kernel on first start, which
takes a few minutes. Precompiled driver images exist only for the kernel
revisions NVIDIA has published tags for, and those lag the distro archive, so
the node's kernel will usually not be among them.

A GPU that enumerates on the bus can still fail to start:

```
NVRM: GPU0 kflcnWaitForHalt_TU102: Timeout waiting for Falcon to halt
NVRM: GPU0 gpuWaitForGfwBootComplete_TU102: GSP failed to halt with GFW_BOOT: (progress 0xff)
NVRM: GPU0 RmInitAdapter: Cannot initialize GSP firmware RM
nvidia-smi: No devices were found
```

Read that from the top, not the bottom. GFW boot is the card running its own
firmware from its own flash on its own PMU and GSP processors at power-on, and
progress `0xff` is the completion value, so the firmware finished. What times
out is the GSP falcon halting afterwards. The host has no part in GFW boot, so
this is not a BIOS video setting, not the primary display adapter, and not the
option ROM.

Three registers off BAR0 tell you where you stand, and they are readable with a
short mmap of `/sys/bus/pci/devices/<addr>/resource0` while the driver is bound:

```
0x000000  PMC_BOOT_0   0xb76000a1   (& 0x1ff00000) >> 20 = 0x176, GA106 rev a1
0x118234  GFW_BOOT     0x000003ff   progress byte 0xff, firmware completed
0x110100  (secured)    0xbadf5620   PRI error, privileged domain unreachable
```

A valid chip ID in `PMC_BOOT_0` means the core has power and clocks, which rules
out the auxiliary power feed, the cable and the slot in one read. Do that before
suspecting any of them.

On a memory-heavy server, check where the card's BARs actually landed. MMIO
placement scales with installed memory, so a 64-bit prefetchable BAR can end up
several terabytes up, somewhere the same card never sees in a workstation.
Dell's guidance for NVIDIA cards in a PowerEdge with a lot of memory is to keep
`Memory Mapped I/O above 4GB` enabled and bring the MMIO base down to 512GB; on
a 13th generation box that is the `LowerMmio` BIOS attribute, and it caps
addressable memory below 512GB in exchange. Worth setting, but it was not the
cause here: it moved this card's BAR1 from `0x3bfe0000000` to `0xbfe0000000`,
42 bits down to 40, and the failure did not change.

The list of things that turned out not to matter on this machine is worth having,
because each one costs a reboot to test: the primary display adapter and the
option ROM, the auxiliary power cable and the riser, the driver branch (595 and
580 fail identically), MMIO base placement, and a full power-off cycle. A
consumer Ampere card that works in a workstation can still fail to hand off its
GSP falcon on a Haswell-era server, and none of the usual server GPU checklists
address it.

### 3. Use the cluster

```bash
kubectl -n metal get metalcluster r730
kubectl -n metal get secret r730-cluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > ~/.kube/r730.kubeconfig
kubectl --kubeconfig ~/.kube/r730.kubeconfig get nodes -o wide
```

The XR reports Ready only once the control plane is up *and* the CNI is installed:

```yaml
status:
  controlPlaneEndpoint: 192.168.120.70:6443
  kubeconfigSecret: r730-cluster-kubeconfig
  controlPlaneAvailable: true
```

## Teardown

Deleting the XR is the teardown. Crossplane owns everything it composed, so this
cascades to the Cluster, which deprovisions the machine and wipes the disk:

```bash
kubectl -n metal delete metalcluster r730
```

If a drain has already cordoned the node, uncordon it before deleting the XR.
The GPU operator uninstalls through a pre-delete hook Job, and a Job that cannot
be scheduled leaves the `Release` uninstalling forever, which the `Usage` then
correctly refuses to let the `Cluster` outrun.

The registered host is not composed, so it survives and returns to `available`,
ready for the next `MetalCluster`. Hardware inventory stays separate from cluster
lifecycle, so a rebuild skips inspection.

To deregister the machine as well:

```bash
kubectl -n metal delete bmh r730
```

Note the BMC credentials Secret is owned by the host, so that removes it too;
recreate it before registering the host again.

## Layout

```
apis/metalclusters/       the MetalCluster XRD and Composition
apis/rbac.yaml            RBAC letting Crossplane compose these types
functions/compose-metal/  the KCL composition function
operations/               Dell virtual media boot recovery
examples/metalcluster/    an example MetalCluster
examples/host/            an example registered machine
tests/test-metalcluster/  offline composition test, no cluster needed
scripts/install-prereqs.sh  everything above the MetalCluster API
```

## Scope

The example builds one machine. Scaling out is a replica count plus a
`MachineDeployment`, with no change to the model. The example also removes the
control-plane taint so the machine can run workloads.

One machine in the pool also means the control plane cannot roll. Changing
anything under `kubeadmConfigSpec` makes `KubeadmControlPlane` stand up a
replacement Machine before retiring the old one, and with no second registered
host that Machine sits at `AssociateBareMetalHost: no available host found`
while `ScalingDown` waits on it. The strategy that would reverse that order is
refused below three replicas:

```
spec.rollout.strategy.rollingUpdate: Required value: when KubeadmControlPlane
is configured to scale-in, replica count needs to be at least 3
```

Deleting the outdated Machine by hand does not break the tie either. KCP holds
a `pre-terminate.delete.hook.machine.cluster.x-k8s.io/kcp-cleanup` hook on it
and will not release that hook while no other control plane Machine is healthy:

```
Cannot delete control plane Machine when there are no control plane Machines
with all Kubernetes control plane components in healthy state
healthyControlPlanes=[] canSafelyTransitionToTargetState=false
```

The replacement cannot get healthy without the host, and the host is not freed
until the hook clears. So a `kubeadmConfigSpec` change on a single-host pool
needs either a second registered host, or deleting the `MetalCluster` and
applying it again, which is the supported teardown and rebuilds against the
current composition.
