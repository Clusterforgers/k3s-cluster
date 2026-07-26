{ self, ... }: {
    flake.nixosModules.kubernetes-deployments = { config, pkgs, ... }: {
        services.k3s.manifests = {
            gateway-api-crds = {
                source = pkgs.fetchurl {
                    url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/experimental-install.yaml";
                    hash = "sha256-EPMidEoAXU5z4rBn6V/s1M/sYZ3HVkkwtIjClr+jvsE=";
                };
            };

            prometheus-stack = {
                content = {
                    apiVersion = "helm.cattle.io/v1";
                    kind = "HelmChart";
                    metadata = { name = "kube-prometheus-stack"; namespace = "kube-system"; };
                    spec = {
                        chart = "kube-prometheus-stack";
                        repo = "https://prometheus-community.github.io/helm-charts";
                        targetNamespace = "monitoring";
                        createNamespace = true;
                    };
                };
            };

            argo-cd = {
                content = {
                    apiVersion = "helm.cattle.io/v1";
                    kind = "HelmChart";
                    metadata = {
                        name = "argo-cd";
                        namespace = "kube-system";
                    };
                    spec = {
                        chart = "argo-cd";
                        repo = "https://argoproj.github.io/argo-helm";
                        targetNamespace = "argocd";
                        createNamespace = true;
                    };
                };
            };
        };
    };
}
