"""
Composition test for MetalCluster.

Runs offline: renders the composition against examples/metalcluster/r730.yaml
and asserts on the output. The assertions cover the decisions
that were non-obvious and expensive to discover, so a regression is caught at
build time rather than after a 20 minute provisioning cycle:

  * hosts are SELECTED by label, never composed (a composed BareMetalHost can
    never be claimed by CAPM3)
  * the control-plane taint list, which decides whether workloads can land on
    control plane machines
  * the CNI is composed, not left as a manual helm step, because without it the
    node never leaves NotReady
  * a Usage orders deletion, so the CNI is uninstalled before its cluster is
    destroyed rather than being stranded on a finalizer
  * diskFormat, which v1beta2 renamed from format
  * a single-address IP pool matching the control plane endpoint
  * the GPU stack takes the DRA path, not the device-plugin path, since the
    two ClusterPolicy/GPUCluster CRs are mutually exclusive and only one of
    them publishes the gpu.nvidia.com DeviceClass
"""

import models.io.k8s.clusterx.infrastructure.v1beta2 as m3
import models.io.metal3.ipam.v1alpha1 as ipam
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-metalcluster"
        spec = {
            compositionPath: "apis/metalclusters/composition.yaml"
            xrdPath: "apis/metalclusters/definition.yaml"
            xrPath: "examples/metalcluster/r730.yaml"
            timeoutSeconds: 120
            validate: False
            assertResources: [
                ipam.IPPool{
                    metadata.name: "r730-pool"
                    spec: {
                        clusterName: "r730-cluster"
                        namePrefix: "r730-node"
                        prefix: 24
                        gateway: "192.168.120.1"
                        pools: [
                            {
                                start: "192.168.120.70"
                                end: "192.168.120.70"
                            }
                        ]
                    }
                }
                m3.Metal3Cluster{
                    metadata.name: "r730-cluster"
                    spec: {
                        cloudProviderEnabled: False
                        controlPlaneEndpoint: {
                            host: "192.168.120.70"
                            port: 6443
                        }
                    }
                }
                m3.Metal3MachineTemplate{
                    metadata.name: "r730-cluster-controlplane"
                    spec.template.spec: {
                        hostSelector.matchLabels: {
                            "metal.kube.farm/pool": "r730"
                        }
                        automatedCleaningMode: "metadata"
                        image: {
                            url: "http://192.168.120.249:8080/UBUNTU_24.04_NODE_IMAGE_K8S_v1.36.2.qcow2"
                            checksum: "df51116494f73337c9ab882f0e16f1aa9910a666325e179741a7ed37af7fe2ce"
                            checksumType: "sha256"
                            diskFormat: "qcow2"
                        }
                    }
                }
                {
                    apiVersion: "helm.m.crossplane.io/v1beta1"
                    kind: "Release"
                    metadata.name: "r730-cluster-cilium"
                    spec: {
                        providerConfigRef: {
                            kind: "ProviderConfig"
                            name: "r730-cluster"
                        }
                        forProvider: {
                            namespace: "kube-system"
                            chart: {
                                name: "cilium"
                                repository: "https://helm.cilium.io"
                                version: "1.20.1"
                            }
                        }
                    }
                }
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "r730-cluster-cilium-needs-cluster"
                    spec: {
                        replayDeletion: True
                        of: {
                            apiVersion: "cluster.x-k8s.io/v1beta2"
                            kind: "Cluster"
                            resourceRef.name: "r730-cluster"
                        }
                        by: {
                            apiVersion: "helm.m.crossplane.io/v1beta1"
                            kind: "Release"
                            resourceRef.name: "r730-cluster-cilium"
                        }
                    }
                }
                {
                    apiVersion: "helm.m.crossplane.io/v1beta1"
                    kind: "ProviderConfig"
                    metadata.name: "r730-cluster"
                    spec.credentials: {
                        source: "Secret"
                        secretRef: {
                            name: "r730-cluster-kubeconfig"
                            key: "value"
                            namespace: "metal"
                        }
                    }
                }
                {
                    apiVersion: "controlplane.cluster.x-k8s.io/v1beta2"
                    kind: "KubeadmControlPlane"
                    metadata.name: "r730-cluster"
                    spec: {
                        replicas: 1
                        version: "v1.36.2"
                        machineTemplate.spec.infrastructureRef: {
                            apiGroup: "infrastructure.cluster.x-k8s.io"
                            kind: "Metal3MachineTemplate"
                            name: "r730-cluster-controlplane"
                        }
                        # The assertion that matters most: an empty taint list.
                        kubeadmConfigSpec.initConfiguration.nodeRegistration.taints: []
                    }
                }
                {
                    apiVersion: "helm.m.crossplane.io/v1beta1"
                    kind: "Release"
                    metadata.name: "r730-cluster-gpu-operator"
                    spec: {
                        providerConfigRef: {
                            kind: "ProviderConfig"
                            name: "r730-cluster"
                        }
                        forProvider: {
                            namespace: "gpu-operator"
                            chart: {
                                name: "gpu-operator"
                                repository: "https://nvidia.github.io/gpu-operator"
                                version: "v26.7.0"
                            }
                            values: {
                                clusterPolicy.deployCR: False
                                gpuCluster.deployCR: True
                                driver: {
                                    nvidiaDriverCRD.enabled: True
                                    usePrecompiled: False
                                }
                            }
                        }
                    }
                }
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "r730-cluster-gpu-needs-cluster"
                    spec: {
                        replayDeletion: True
                        of: {
                            apiVersion: "cluster.x-k8s.io/v1beta2"
                            kind: "Cluster"
                            resourceRef.name: "r730-cluster"
                        }
                        by: {
                            apiVersion: "helm.m.crossplane.io/v1beta1"
                            kind: "Release"
                            resourceRef.name: "r730-cluster-gpu-operator"
                        }
                    }
                }
            ]
        }
    }
]
