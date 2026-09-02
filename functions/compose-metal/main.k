"""
compose-metal: turn a MetalCluster into the Metal3 and Cluster API object graph
that provisions a Kubernetes cluster on a physical server.

Composes IPPool, Cluster, Metal3Cluster, Metal3MachineTemplate,
Metal3DataTemplate, KubeadmControlPlane, and a provider-helm ProviderConfig and
Release for the CNI.

The BareMetalHost and its credentials Secret are not composed; hosts
are registered separately and selected by label.
"""

import models.farm.kube.metal.v1alpha1 as metalv1
import models.io.metal3.ipam.v1alpha1 as ipam
import models.io.k8s.clusterx.v1beta2 as capi
import models.io.k8s.clusterx.infrastructure.v1beta2 as m3

oxr = option("params").oxr
_ocds = option("params").ocds

_name = oxr.metadata.name
_spec = oxr.spec

_host = _spec.host
_net = _spec.network
_k8s = _spec.kubernetes
_cni = _spec.cni
_ns = oxr.metadata.namespace

_cluster = "{}-cluster".format(_name)
_pool = "{}-pool".format(_name)
_cpTemplate = "{}-controlplane".format(_cluster)
_dataTemplate = "{}-controlplane-template".format(_cluster)

# Cluster API objects carry no Crossplane-style Ready condition, so readiness is
# declared here rather than inferred.
_metadata = lambda n: str -> any {
    {annotations = {
        "krm.kcl.dev/composition-resource-name" = n
        "krm.kcl.dev/ready" = "True"
    }}
}

# For resources that do carry a real Ready condition, say nothing and let
# function-auto-ready use the observed state.
_metadataAuto = lambda n: str -> any {
    {annotations = {"krm.kcl.dev/composition-resource-name" = n}}
}

# Same as _metadata, but readiness is conditional on the observed object.
_metadataReady = lambda n: str, ready: bool -> any {
    {annotations = {
        "krm.kcl.dev/composition-resource-name" = n
        "krm.kcl.dev/ready" = "True" if ready else "False"
    }}
}

# Real readiness: is the control plane actually up?
_observedCluster = _ocds["cluster"].Resource if "cluster" in _ocds else Undefined
_clusterConditions = (_observedCluster?.status?.conditions) or []
_clusterAvailable = len([
    c for c in _clusterConditions if c.type == "Available" and c.status == "True"
]) > 0

# kubelet needs the node name and the metal3 uuid label; these are rendered by
# the Metal3 data template at provisioning time, not by KCL.
_nodeRegistration = {
    name = "{{ ds.meta_data.name }}"
    # Empty taint list overrides kubeadm's default
    # node-role.kubernetes.io/control-plane:NoSchedule so control plane machines
    # also run workloads. Drop once there are dedicated workers. Labels are
    # untouched; Cluster API relies on them to identify the node.
    taints = []
    kubeletExtraArgs = [
        {
            name = "node-labels"
            value = "metal3.io/uuid={{ ds.meta_data.uuid }}"
        }
    ]
}

items = [
    ipam.IPPool {
        metadata = _metadata("ippool") | {name = _pool}
        spec = {
            clusterName = _cluster
            namePrefix = "{}-node".format(_name)
            prefix = _net.prefix
            gateway = _net.gateway
            dnsServers = [_net.dnsServer]
            pools = [
                {
                    start = _net.nodeIP
                    end = _net.nodeIP
                }
            ]
        }
    }
    capi.Cluster {
        metadata = _metadataReady("cluster", _clusterAvailable) | {name = _cluster}
        spec = {
            clusterNetwork = {
                pods = {cidrBlocks = [_net.podCIDR]}
                services = {cidrBlocks = [_net.serviceCIDR]}
                serviceDomain = "cluster.local"
            }
            controlPlaneRef = {
                apiGroup = "controlplane.cluster.x-k8s.io"
                kind = "KubeadmControlPlane"
                name = _cluster
            }
            infrastructureRef = {
                apiGroup = "infrastructure.cluster.x-k8s.io"
                kind = "Metal3Cluster"
                name = _cluster
            }
        }
    }
    m3.Metal3Cluster {
        metadata = _metadata("metal3cluster") | {name = _cluster}
        spec = {
            # No cloud controller manager exists here; true makes kubelet wait
            # forever to be initialised by one.
            cloudProviderEnabled = False
            controlPlaneEndpoint = {
                host = _net.nodeIP
                port = 6443
            }
        }
    }
    m3.Metal3MachineTemplate {
        metadata = _metadata("metal3machinetemplate") | {name = _cpTemplate}
        spec = {
            nodeReuse = False
            template = {
                spec = {
                    # Any available BareMetalHost carrying the pool label.
                    hostSelector = {
                        matchLabels = {
                            "metal.kube.farm/pool" = _host.pool
                        }
                    }
                    # metadata, not a full secure erase, which takes hours.
                    automatedCleaningMode = "metadata"
                    dataTemplate = {name = _dataTemplate}
                    image = {
                        url = _k8s.imageURL
                        checksum = _k8s.imageChecksum
                        checksumType = _k8s.imageChecksumType
                        # v1beta2 renamed this from `format`.
                        diskFormat = _k8s.imageDiskFormat
                    }
                }
            }
        }
    }
    m3.Metal3DataTemplate {
        metadata = _metadata("metal3datatemplate") | {name = _dataTemplate}
        spec = {
            clusterName = _cluster
            # Without this the node takes a DHCP address that will not match
            # controlPlaneEndpoint. The MAC comes from inspection data.
            networkData = {
                links = {
                    ethernets = [
                        {
                            type = "phy"
                            id = _host.bootInterface
                            macAddress = {
                                fromHostInterface = _host.bootInterface
                            }
                        }
                    ]
                }
                networks = {
                    ipv4 = [
                        {
                            id = "baremetal"
                            link = _host.bootInterface
                            ipAddressFromIPPool = _pool
                            routes = [
                                {
                                    network = "0.0.0.0"
                                    prefix = 0
                                    gateway = {fromIPPool = _pool}
                                }
                            ]
                        }
                    ]
                }
                services = {
                    dns = [_net.dnsServer]
                }
            }
        }
    }
    # Untyped, unlike the rest. `up` deduplicates apiDependencies by repository,
    # so the cluster-api CRDs can only be pulled from one path, and core (for
    # Cluster) is the more valuable one. Everything else here is type-checked.
    {
        apiVersion = "controlplane.cluster.x-k8s.io/v1beta2"
        kind = "KubeadmControlPlane"
        metadata = _metadata("kubeadmcontrolplane") | {name = _cluster}
        spec = {
            replicas = 1
            version = _k8s.version
            machineTemplate = {
                spec = {
                    infrastructureRef = {
                        apiGroup = "infrastructure.cluster.x-k8s.io"
                        kind = "Metal3MachineTemplate"
                        name = _cpTemplate
                    }
                }
            }
            kubeadmConfigSpec = {
                initConfiguration = {nodeRegistration = _nodeRegistration}
                joinConfiguration = {
                    controlPlane = {}
                    nodeRegistration = _nodeRegistration
                }
            }
        }
    }
    # Without a CNI the node never leaves NotReady, so composing it is what
    # makes one apply produce a working cluster.
    #
    # Credentials are the kubeconfig Secret Cluster API emits. It does not exist
    # until the control plane is up; Crossplane reconciles until it does.
    #
    # helm.m.crossplane.io is the namespaced API group a namespaced XR composes.
    {
        apiVersion = "helm.m.crossplane.io/v1beta1"
        kind = "ProviderConfig"
        metadata = _metadata("helm-providerconfig") | {
            name = _cluster
            namespace = _ns
        }
        spec = {
            credentials = {
                source = "Secret"
                secretRef = {
                    namespace = _ns
                    name = "{}-kubeconfig".format(_cluster)
                    key = "value"
                }
            }
        }
    }
    {
        apiVersion = "helm.m.crossplane.io/v1beta1"
        kind = "Release"
        # No readiness annotation: a helm Release has a real Ready condition, so
        # the XR only reports Ready once the CNI is installed.
        metadata = _metadataAuto("cilium") | {
            name = "{}-cilium".format(_cluster)
            namespace = _ns
        }
        spec = {
            providerConfigRef = {
                # kind is required on namespaced managed resources.
                kind = "ProviderConfig"
                name = _cluster
            }
            forProvider = {
                namespace = "kube-system"
                chart = {
                    name = "cilium"
                    repository = "https://helm.cilium.io"
                    version = _cni.ciliumVersion
                }
                values = {
                    operator = {replicas = 1}
                    # Kubernetes hands out pod CIDRs, so podCIDR stays the single
                    # source of truth.
                    ipam = {mode = "kubernetes"}
                }
            }
        }
    }
    {
        apiVersion = "protection.crossplane.io/v1beta1"
        kind = "Usage"
        metadata = _metadata("cilium-needs-cluster") | {
            name = "{}-cilium-needs-cluster".format(_cluster)
            namespace = _ns
        }
        spec = {
            reason = "Cilium must be uninstalled before the cluster hosting it is destroyed."
            replayDeletion = True
            of = {
                apiVersion = "cluster.x-k8s.io/v1beta2"
                kind = "Cluster"
                resourceRef = {name = _cluster}
            }
            by = {
                apiVersion = "helm.m.crossplane.io/v1beta1"
                kind = "Release"
                resourceRef = {name = "{}-cilium".format(_cluster)}
            }
        }
    }
    # Updating the composite goes through `items` as well.
    metalv1.MetalCluster {
        metadata = {
            name = _name
            namespace = oxr.metadata.namespace
        }
        # The typed model requires spec, so echo the observed one back.
        spec = oxr.spec
        status = {
            controlPlaneEndpoint = "{}:6443".format(_net.nodeIP)
            kubeconfigSecret = "{}-kubeconfig".format(_cluster)
            hostPool = _host.pool
            controlPlaneAvailable = _clusterAvailable
        }
    }
]
