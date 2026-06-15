# Smart Inbox Triage Agent

### BRK221 — "Idea to Production-Ready Agent in Seconds on AI-native Runtime"

### Microsoft Build //localhost Utrecht · June 15, 2026

---

## What This Is

A production-ready agentic AI application that triages a business inbox in seconds.

The agent reads each email, then autonomously:

- Classifies urgency (High / Medium / Low)
- Categorises the email type
- Routes it to the right team
- Writes a one-line summary
- Drafts a professional reply ready to send
- Recommends the next action

It runs as a containerised FastAPI app on **Azure Container Apps**, powered by **GPT-4.1 mini** via **Azure AI Foundry**, with KEDA HTTP autoscaling, scale-to-zero, and Application Insights observability.

---

## Project Structure

```
email-triage-agent/
├── app/
│   ├── main.py              # FastAPI app + agentic logic
│   ├── requirements.txt
│   ├── Dockerfile
│   └── static/
│       └── index.html       # Full UI (dark theme, SSE streaming)
├── terraform/
│   ├── main.tf              # Full production IaC
│   └── terraform.tfvars.example
└── deploy/
    ├── deploy.sh            # az CLI — fastest path (live demo)
    └── teardown.sh          # Clean up after the demo
```

---

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Docker installed (only needed if building locally — the script uses `az acr build` which builds in the cloud)
- Terraform >= 1.5 (for the Terraform path)
- An Azure subscription with:
  - Quota for `GPT-4.1-mini` in a preferred location (check via AI Foundry portal)
  - Contributor access

---

## Option A — Live Demo Path (az CLI, ~5 minutes)

This is the path that runs on stage. It builds and deploys everything from a single script.

### Step 1 — Set your subscription ID

Edit `deploy/deploy.sh` and replace `SUBSCRIPTION-ID` with your actual subscription ID:

```bash
# Find it with:
az account show --query id -o tsv
```

### Step 2 — Run the deploy script

```bash
chmod +x deploy/deploy.sh
bash deploy/deploy.sh
```

The script does these 7 steps, showing progress for each:

1. Creates the resource group
2. Creates Azure Container Registry (Basic SKU)
3. Builds the container image in ACR (no local Docker needed)
4. Creates Log Analytics workspace
5. Creates Azure AI Foundry (OpenAI) + deploys GPT-4.1 mini (30K TPM cap)
6. Creates ACA environment with Log Analytics attached
7. Deploys the container app with KEDA HTTP scale rule

### Step 3 — Open the app

The URL is printed at the end. It looks like:

```
https://ca-triage-demo.westeurope.azurecontainerapps.io
```

### Step 4 — Teardown after the demo

```bash
bash deploy/teardown.sh
```

This deletes the entire resource group. Your subscription stays clean.

---

## Option B — Terraform (Production Path)

Use this concept for the full Infrastructure as Code using terraform. You could modularize it within an existing terraform project.

```bash
cd terraform

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set subscription_id

terraform init

# Run and save the plan with -out flag to ensure the exact changes planned are applied.
terraform plan -out=<FILENAME>
terraform apply <FILENAME>
```

Outputs printed after apply:

- `app_url` — live URL
- `app_insights_url` — direct link to Application Insights
- `acr_login_server` — for pushing new image tags

To push a new image after code changes:

```bash
ACR=$(terraform output -raw acr_login_server)
az acr build --registry ${ACR%%.*} --image email-triage-agent:latest ./app
az containerapp update --name ca-triage-demo --resource-group rg-triage-demo \
  --image "${ACR}/email-triage-agent:latest"
```

---

## Architecture

```
                  ┌─────────────────────────────────────┐
                  │       Azure Container Apps          │
                  │                                     │
  Browser ──────► │  FastAPI App (Python)               │
  (HTTPS)         │  ├── GET /            → UI          │
                  │  ├── GET /api/sample-emails         │
                  │  └── POST /api/triage/stream        │
                  │       │                             │
                  │       ▼                             │
                  │  Agent Loop (per email)             │
                  │  └── System prompt + email →        │
                  │       GPT-4.1 mini                  │
                  │       ↓ JSON response               │
                  │  SSE stream → browser               │
                  │                                     │
                  │  KEDA HTTP scaler                   │
                  │  (0 → 10 replicas on concurrency)   │
                  └──────────────┬──────────────────────┘
                                 │
              ┌──────────────────┼────────────────────┐
              │                  │                    │
    ┌─────────▼──────┐  ┌────────▼────────┐  ┌────────▼────────┐
    │  Azure AI      │  │  Application    │  │  Azure Container│
    │  Foundry       │  │  Insights       │  │  Registry (ACR) │
    │  GPT-4.1 mini  │  │  + Log Analytics│  │  email-triage   │
    │  30K TPM cap   │  │  (OTel traces)  │  │  agent:latest   │
    └────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## Model Selection: Why GPT-4.1 mini?

This is a deliberate choice:

| Model | Cost (input/output per 1M tokens) | Context | Best for |
|---|---|---|---|
| **GPT-4.1 mini** ✅ | $0.15 / $0.60 | 128K | Tool-calling, classification, drafting |
| GPT-4.1-mini | $0.40 / $1.60 | 1M | Complex instruction-following |
| GPT-4.1-nano | $0.10 / $0.40 | 1M | Ultra-fast classification only |
| GPT-4.1 | $2.50 / $10.00 | 128K | Hard reasoning, vision |
| Phi-4 (self-hosted) | Per GPU-second | 16K | Data residency, no token cost |

**The case for GPT-4.1 mini here:**

- Email triage doesn't need frontier-level reasoning
- It needs reliable JSON output + good writing quality
- At $0.15/1M input: triaging 1,000 emails costs less than €0.20
- The 30K TPM cap on the deployment protects against runaway costs

**Token management talking point:**

- Each email triage call uses ~200-400 tokens
- System prompt is ~150 tokens (fixed overhead)
- Cap the deployment at 30K TPM: enough for the demo, safe for a shared subscription
- In production: use Azure AI Foundry Model Router to route simple emails to nano, complex ones to mini

---

## Local Testing (before the event)

```bash
cd app

# Set env vars
export AZURE_OPENAI_ENDPOINT="https://oai-triage-demo.openai.azure.com/"
export AZURE_OPENAI_API_KEY="your-key-here"
export AZURE_OPENAI_DEPLOYMENT="GPT-4.1-mini"

pip install -r requirements.txt
uvicorn main:app --reload --port 8000
# Open http://localhost:8000
```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| App returns 500 on triage | Check `AZURE_OPENAI_API_KEY` and `ENDPOINT` env vars in ACA → Containers → Environment Variables |
| `az acr build` fails | Ensure you're in the repo root when running `deploy.sh` |
| Model deployment quota error | Request GPT-4.1 mini quota in a preferred location via AI Foundry portal or support ticket |
| App not reachable after deploy | First request after scale-to-zero takes ~3-5s cold start — refresh once |
| Terraform `azapi` provider not found | Run `terraform init` again; ensure internet access from your machine |

---

## Costs (Subscription estimate for demo)

| Resource | SKU | Estimated cost |
|---|---|---|
| ACA (0.5 CPU, 1GB) | Consumption | ~€0.01/hour active |
| ACR | Basic | ~€0.15/day |
| GPT-4.1 mini | 30K TPM, Standard | Pay-as-you-go, ~€0.01 for full demo |
| Log Analytics | PerGB2018 | ~€0.00 (minimal data) |
| App Insights | Per GB | ~€0.00 (minimal data) |

**Total for a 1-day demo: < €1.00**
