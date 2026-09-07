#!/usr/bin/env bash
set -euo pipefail

echo "Deploying to $1..."
kubectl apply -f ./k8s/
echo "Deploy done."
