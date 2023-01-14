#!/bin/bash
set -e

USAGE="./update-ingress.sh INGRESS_CONTROLLER_VERSION"
REQ_PATH="k8s-configs/cluster-tools/base/ingress/nginx/base"

if [[ ! "$(pwd)" = *"${REQ_PATH}"* ]]; then
    echo "Script run source sanity check failed. Please only run this script in ${REQ_PATH}"
    exit 1
fi

if [[ $# != 1 ]]; then
    echo "Usage: ${USAGE}"
    exit 1
fi

INGRESS_CONTROLLER_VERSION="${1}"

curl "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_CONTROLLER_VERSION}/deploy/static/provider/aws/deploy.yaml" -o install.yaml

echo "Ingress Controller update complete, check your 'git diff' to see what changed"
