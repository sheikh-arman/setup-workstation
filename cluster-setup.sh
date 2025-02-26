#!/bin/bash

kubedb=1
kubestash=1
stash=0
longhorn=1
metrics=1
prom=1
panopticon=1
metricsapi=1

#kubedb
if [ $kubedb -eq 1 ]; then
helm upgrade -i kubedb oci://ghcr.io/appscode-charts/kubedb \
    --version v2025.2.19 \
    --namespace kubedb --create-namespace \
    --set-file global.license=license.txt \
    --set global.featureGates.ClickHouse=true \
    --set global.featureGates.PerconaXtraDB=true \
    --set global.featureGates.ProxySQL=true \
    --wait --burst-limit=10000 --debug
fi

#kubestash
if [ $kubestash -eq 1 ]; then
helm upgrade -i kubestash oci://ghcr.io/appscode-charts/kubestash \
     --version v2025.2.10 \
     --set-file global.license=license.txt \
     --namespace kubestash --create-namespace \
     --wait --burst-limit=10000 --debug
fi

#stash
if [ $stash -eq 1 ]; then
helm upgrade -i stash oci://ghcr.io/appscode-charts/stash \
  --version v2025.2.10 \
  --namespace stash --create-namespace \
  --set features.enterprise=true \
  --set-file global.license=$HOME/Downloads/kubedb-license-b36d84ff-b7ab-4e83-92a1-dd0aa93779a5.txt \
  --wait --burst-limit=10000 --debug
fi

#longhorn
if [ $longhorn -eq 1 ]; then
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm upgrade -i longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --version 1.7.2
fi

#metrics config
if [ $metrics -eq 1 ]; then
helm repo add appscode https://charts.appscode.com/stable/
helm repo update
helm search repo appscode/kubedb-metrics --version=v2024.8.21
helm upgrade -i kubedb-metrics appscode/kubedb-metrics -n kubedb --create-namespace --version=v2024.8.21
fi

#promethus
if [ $prom -eq 1 ]; then
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n monitoring --set grafana.image.tag=7.5.5 --create-namespace
fi

# panopticon
if [ $panopticon -eq 1 ]; then
helm upgrade -i panopticon appscode/panopticon -n kubeops --create-namespace --version=v2024.11.8 \
   --set monitoring.enabled=true \
   --set monitoring.agent=prometheus.io/operator \
   --set monitoring.serviceMonitor.labels.release=prometheus \
   --set-file license=license.txt
fi

if [ $metricsapi -eq 1 ]; then
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi










