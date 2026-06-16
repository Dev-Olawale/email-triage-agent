#!/bin/bash
# Tear down all demo resources from your subscription
set -e
export PYTHONIOENCODING="utf-8"
export PYTHONUTF8="1"

PREFIX="triage"
RG="rg-${PREFIX}-demo"
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

az account set --subscription "$SUBSCRIPTION"

echo "▶ Deleting resource group ${RG} (all resources inside)..."
az group delete --name "$RG" --yes --no-wait

echo "✅ Deletion kicked off. Resources will be gone in ~2 minutes."
