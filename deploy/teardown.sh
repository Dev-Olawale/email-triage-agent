#!/bin/bash
# Tear down all demo resources from your subscription
set -euo pipefail
export PYTHONIOENCODING="utf-8"
export PYTHONUTF8="1"

PREFIX="triage"
LOCATION="swedencentral"
RG="rg-${PREFIX}-demo"
OPENAI_NAME="oai-${PREFIX}-demo"
OPENAI_LOCATION="$LOCATION"
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
DELETE_TIMEOUT_SECONDS="${DELETE_TIMEOUT_SECONDS:-900}"

az account set --subscription "$SUBSCRIPTION"

if [ "$(az group exists --name "$RG")" = "true" ]; then
  echo "▶ Deleting resource group ${RG} (all resources inside)..."
  az group delete --name "$RG" --yes --no-wait

  echo "▶ Waiting for resource group deletion to complete..."
  az group wait \
    --name "$RG" \
    --deleted \
    --interval 15 \
    --timeout "$DELETE_TIMEOUT_SECONDS"
else
  echo "▶ Resource group ${RG} does not exist; skipping delete."
fi

echo "▶ Purging soft-deleted Azure OpenAI resource ${OPENAI_NAME}..."
if az cognitiveservices account purge \
  --resource-group "$RG" \
  --name "$OPENAI_NAME" \
  --location "$OPENAI_LOCATION" \
  --output none; then
  echo "✅ Purged ${OPENAI_NAME}."
else
  echo "ℹ️ No soft-deleted Azure OpenAI resource named ${OPENAI_NAME} was found to purge."
fi

echo "✅ Teardown complete."
