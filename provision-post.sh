#!/usr/bin/env bash
set -xeuo pipefail

node_ipv4_public="$1"

k3os_user=rancher
ssh_key=secrets/ssh-terraform
ssh_opts="-o StrictHostKeyChecking=no"

ssh="ssh $ssh_opts -i $ssh_key ${k3os_user}@${node_ipv4_public}"
kubectl="$ssh kubectl"
kaf="$kubectl apply -f -"

one_off_manifest=${2:-""}
[ "$one_off_manifest" ] && {
	$kaf < "$one_off_manifest"
	exit 0
}

ingress_nginx_ver="nginx-0.30.0"
ingress_nginx_manifest_url1="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${ingress_nginx_ver}/deploy/static/mandatory.yaml"
ingress_nginx_manifest_url2="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${ingress_nginx_ver}/deploy/static/provider/baremetal/service-nodeport.yaml"

longhorn_ver="v0.8.0"
longhorn_manifest_url="https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_ver}/deploy/longhorn.yaml"

certmanager_ver="v0.14.1"
certmanager_manifest_url="https://github.com/jetstack/cert-manager/releases/download/${certmanager_ver}/cert-manager.yaml"

# need to pre-create these so we can restore the TLS certs to them
for namespace in prometheus longhorn-system; do
	$kubectl create namespace "$namespace" || true
done

for tls_cert in secrets/*-cert.yaml; do
	$kaf < "${tls_cert}"
done

for url in \
	"$ingress_nginx_manifest_url1" \
	"$ingress_nginx_manifest_url2" \
	"$longhorn_manifest_url" \
	"$certmanager_manifest_url"; do
	curl --location --silent "$url" | $kaf
done

# make ingress a LB so that svclb picks it up
$kubectl patch service -n ingress-nginx ingress-nginx -p \''{"spec":{"type":"LoadBalancer"}}'\'

# ensure certmanager is ready
while [ "$($kubectl get pods -n cert-manager -l app=webhook -o json | jq '.items[0].status.containerStatuses[0].ready')" != true ]; do
	sleep 5
done

# install the rest
for f in manifests/*; do
	$kaf < "$f"
done
