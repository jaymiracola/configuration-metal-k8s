"""
Composition test for MetalCluster. Renders the composition against
examples/metalcluster/r730.yaml offline and asserts on the output.
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
                            url: "http://192.168.120.249:8080/CENTOS_10_NODE_IMAGE_K8S_v1.36.2.qcow2"
                            checksum: "a6ecbde797e3b5592b4e500b9f8b6bb12bfd4b9cf4ca67bef6c023b439698496"
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
                            values: {
                                ipam.mode: "kubernetes"
                                # Bare metal has no cloud load balancer, so
                                # Cilium has to answer ARP for Service IPs.
                                l2announcements.enabled: True
                                k8sClientRateLimit.qps: 50
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
                        # nodeLabels are appended to the metal3 uuid label as
                        # one comma-separated kubelet argument.
                        kubeadmConfigSpec.initConfiguration.nodeRegistration.kubeletExtraArgs: [
                            {
                                name: "node-labels"
                                value: "metal3.io/uuid={{ ds.meta_data.uuid }},node.kubernetes.io/instance-type=r730"
                            }
                        ]
                        # Six separate commands, not one concatenated string,
                        # which is the failure mode a comma-free KCL list has.
                        kubeadmConfigSpec.preKubeadmCommands: [
                            "systemctl enable --now crio"
                            "echo blacklist nouveau > /etc/modprobe.d/blacklist-nouveau.conf"
                            "modprobe -r nouveau || true"
                            "dnf install -y kernel-devel-$(uname -r) gcc make elfutils-libelf-devel"
                            "curl -fsSL -o /tmp/nvidia-driver.run http://192.168.120.249:8080/NVIDIA-Linux-x86_64-580.178.04.run"
                            "sh /tmp/nvidia-driver.run --silent --no-x-check --no-nouveau-check"
                            "modprobe nvidia"
                        ]
                    }
                }
            ]
        }
    }
]
