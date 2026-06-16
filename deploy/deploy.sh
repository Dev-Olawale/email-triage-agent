#!/bin/bash
# ============================================================
# Smart Inbox Triage Agent — Live Demo Deploy Script
# BRK221 · Microsoft Build //localhost Utrecht 2026
# Run this from the repo root: bash deploy/deploy.sh
# ============================================================
set -e
export PYTHONIOENCODING="utf-8"
export PYTHONUTF8="1"

# ── CONFIG ── edit these before the demo ──────────────────
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="swedencentral"
PREFIX="triage"
RG="rg-${PREFIX}-demo"
ACR_NAME="acr${PREFIX}demo"
ENV_NAME="cae-${PREFIX}-demo"
APP_NAME="ca-${PREFIX}-demo"
OPENAI_NAME="oai-${PREFIX}-demo"
OPENAI_LOCATION="swedencentral"
LAW_NAME="law-${PREFIX}-demo"
IMAGE="email-triage-agent"
TAG="latest"
# ──────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Smart Inbox Triage Agent — ACA Live Deploy         ║"
echo "║   BRK221 · Microsoft Build //localhost 2026          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

az account set --subscription "$SUBSCRIPTION"

# ── 1. Resource Group ──────────────────────────────────────
echo "▶ [1/8] Creating resource group..."
az group create \
  --name "$RG" \
  --location "$LOCATION" \
  --output none

# ── 2. Container Registry ──────────────────────────────────
echo "▶ [2/8] Creating Azure Container Registry..."
az acr create \
  --resource-group "$RG" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --output none

# ── 3. Build + Push image ──────────────────────────────────
echo "▶ [3/8] Building and pushing container image..."
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE}:${TAG}" \
  ./app \
  --output none

ACR_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
ACR_USER=$(az acr credential show --name "$ACR_NAME" --query username -o tsv)
ACR_PASS=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)

# ── 4. Log Analytics ───────────────────────────────────────
echo "▶ [4/8] Creating Log Analytics workspace..."
az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$LAW_NAME" \
  --output none

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" \
  --workspace-name "$LAW_NAME" \
  --query customerId -o tsv)

LAW_KEY=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$RG" \
  --workspace-name "$LAW_NAME" \
  --query primarySharedKey -o tsv)

# ── 5. Azure OpenAI (AI Foundry) ───────────────────────────
echo "▶ [5/8] Creating Azure AI Foundry (OpenAI) resource..."
az cognitiveservices account create \
  --name "$OPENAI_NAME" \
  --resource-group "$RG" \
  --location "$OPENAI_LOCATION" \
  --kind OpenAI \
  --sku S0 \
  --custom-domain "$OPENAI_NAME" \
  --yes \
  --output none

az cognitiveservices account deployment create \
  --name "$OPENAI_NAME" \
  --resource-group "$RG" \
  --deployment-name "gpt-4.1-mini" \
  --model-name "gpt-4.1-mini" \
  --model-version "2025-04-14" \
  --model-format OpenAI \
  --sku-capacity 30 \
  --sku-name "Standard" \
  --output none

OPENAI_ENDPOINT=$(az cognitiveservices account show \
  --name "$OPENAI_NAME" \
  --resource-group "$RG" \
  --query properties.endpoint -o tsv)

OPENAI_KEY=$(az cognitiveservices account keys list \
  --name "$OPENAI_NAME" \
  --resource-group "$RG" \
  --query key1 -o tsv)

# ── 6. ACA Environment ─────────────────────────────────────
echo "▶ [6/8] Creating ACA Environment..."
az containerapp env create \
  --name "$ENV_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --logs-workspace-id "$LAW_ID" \
  --logs-workspace-key "$LAW_KEY" \
  --output none

# ── 7. Deploy Container App ────────────────────────────────
echo "▶ [7/8] Deploying container app..."
az containerapp create \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --environment "$ENV_NAME" \
  --image "${ACR_SERVER}/${IMAGE}:${TAG}" \
  --registry-server "$ACR_SERVER" \
  --registry-username "$ACR_USER" \
  --registry-password "$ACR_PASS" \
  --target-port 8000 \
  --ingress external \
  --min-replicas 0 \
  --max-replicas 10 \
  --cpu 0.5 \
  --memory 1Gi \
  --scale-rule-name "http-scaler" \
  --scale-rule-type "http" \
  --scale-rule-http-concurrency 10 \
  --env-vars \
    "AZURE_OPENAI_ENDPOINT=${OPENAI_ENDPOINT}" \
    "AZURE_OPENAI_DEPLOYMENT=gpt-4.1-mini" \
    "AZURE_OPENAI_API_KEY=secretref:openai-key" \
  --secrets "openai-key=${OPENAI_KEY}" \
  --output none

APP_URL=$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --query properties.configuration.ingress.fqdn -o tsv)

# ── 8. Done ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  DEPLOYED SUCCESSFULLY                           ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  App URL:  https://${APP_URL}"
echo "║  Resource Group: ${RG}"
echo "║  Model: GPT-4.1 mini (30K TPM cap)"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Open the app: https://${APP_URL}"

# List available models in the Azure OpenAI resource (optional)
# az cognitiveservices model list \
#   --location "swedencentral" \
#   --query "[].{name:model.name, version:model.version} | sort_by(@, &name)" \
#   -o table
