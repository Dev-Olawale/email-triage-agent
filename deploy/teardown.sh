#!/bin/bash
# Tear down all demo resources from your subscription
set -e

PREFIX="triage"
RG="rg-${PREFIX}-demo"
SUBSCRIPTION="SUBSCRIPTION-ID"

az account set --subscription "$SUBSCRIPTION"

echo "▶ Deleting resource group ${RG} (all resources inside)..."
az group delete --name "$RG" --yes --no-wait

echo "✅ Deletion kicked off. Resources will be gone in ~2 minutes."
