# configuration-metal-k8s

This repository contains an Upbound project that turns a registered bare-metal
server into a Kubernetes cluster ready to serve inference, from one API object.
It composes [Metal3](https://metal3.io) and [Cluster
API](https://cluster-api.sigs.k8s.io) resources, so a physical machine is
requested the same way as any cloud resource.

## Overview

The `MetalCluster` API contains:

- **a [MetalCluster](/apis/metalclusters/definition.yaml) custom resource type**
- **[Composition](/apis/metalclusters/composition.yaml)** of an `IPPool`,
  `Cluster`, `Metal3Cluster`, `Metal3MachineTemplate`, `Metal3DataTemplate` and
  `KubeadmControlPlane`, plus a provider-helm `ProviderConfig` and `Release`
  for the CNI
- **[Embedded function](/functions/compose-metal/main.k)** holding the
  composition logic in KCL

Cluster API Provider Metal3 claims a registered host, Ironic powers it through
the BMC and attaches a boot ISO as virtual media, kubeadm runs, and the CNI is
installed so the node reaches `Ready` unattended.

Hosts are inventory: registered once, selected by label, and they outlive the
clusters built on them.

## Prerequisites

- A management cluster running Crossplane.
  [`scripts/install-prereqs.sh`](/scripts/install-prereqs.sh) installs the rest:
  cert-manager, Metal3's Bare Metal Operator and Ironic, Cluster API with the
  kubeadm, Metal3 and IPAM providers, the [RBAC](/examples/rbac.yaml) that lets
  Crossplane compose those types, and a mirror of the node image on the
  management network.
- A server whose BMC speaks Redfish with virtual media enabled, set to UEFI boot
  with Secure Boot off, and a disk that can be erased.

## Deployment

- Execute `up project run`
- Register a host with [`examples/host`](/examples/host/). Its MAC, root device
  WWN and boot interface name come from Ironic's inspection data.
- Apply an XR from [`examples/metalcluster`](/examples/metalcluster/)

Deleting the XR is the teardown. It deprovisions the machine and wipes the disk;
the registered host survives and returns to `available`.

## GPU and inference

`gpu.driverInstallerURL` installs an NVIDIA kernel driver from
`preKubeadmCommands`, before kubeadm runs, which keeps the node image stock.

Nothing above that is installed. The GPU Operator, Modelplane and a standalone
DRA driver all expect to own the `DeviceClass` objects, so the cluster is handed
over with a working driver and the consumer chooses. To register it with
[Modelplane](https://docs.modelplane.ai), create an `InferenceClass` describing
the device and an `InferenceCluster` with `source: Existing` pointing at the
Cluster API kubeconfig `Secret`, copied into `modelplane-system`.

## Operations

[`operations/`](/operations/) carries a `WatchOperation` that repairs Dell
virtual media boots. Ironic's one-shot boot override loses to an installed OS,
so booting the ramdisk fails once the disk holds a bootable system. Apply it on
Dell hardware; remove it if the override works.

## Testing

- `up test run tests/*` runs the composition tests in `tests/test-metalcluster/`

## Scope

The example builds a single node with the control-plane taint removed. Scaling
out is a replica count plus a `MachineDeployment`, with no change to the model.

One host in the pool means the control plane cannot roll, because
`KubeadmControlPlane` stands up a replacement before retiring the old one and
there is nowhere to put it. Register a second host, or re-apply the XR.
