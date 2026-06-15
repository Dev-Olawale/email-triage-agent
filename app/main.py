import os
import json
import asyncio
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse, FileResponse
from pydantic import BaseModel
from openai import AzureOpenAI
from typing import List

app = FastAPI(title="Smart Inbox Triage Agent")
app.mount("/static", StaticFiles(directory="static"), name="static")

client = AzureOpenAI(
    api_key=os.environ["AZURE_OPENAI_API_KEY"],
    api_version="2024-12-01-preview",
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
)
DEPLOYMENT = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4.1-mini")

SAMPLE_EMAILS = [
    {
        "id": 1,
        "from": "angry.customer@acmecorp.com",
        "subject": "Invoice #4421 still unpaid after 60 days!!!",
        "body": "This is absolutely unacceptable. We submitted invoice #4421 on April 3rd for €12,400. It is now over 60 days and we have received nothing. Our finance director is threatening legal action if this is not resolved by end of week. I need an urgent response.",
    },
    {
        "id": 2,
        "from": "hr@globalpartners.nl",
        "subject": "Interview scheduling - Thursday or Friday?",
        "body": "Hi, we'd like to schedule a second-round interview for the Senior DevOps role. We have availability on Thursday 19th June at 10am or Friday 20th June at 2pm. Please let us know which works best. The panel will include our CTO and Head of Engineering.",
    },
    {
        "id": 3,
        "from": "newsletter@techdigest.io",
        "subject": "This week in cloud: Azure, AWS, and GCP updates",
        "body": "Here's your weekly roundup of the top cloud news. Azure announced new GPU SKUs, AWS launched Bedrock updates, and GCP dropped prices on storage tiers. Plus: our take on the AI regulation landscape in the EU.",
    },
    {
        "id": 4,
        "from": "m.jansen@teamlead.internal",
        "subject": "Can you review the Q3 deployment runbook?",
        "body": "Hey, I've finished the first draft of the Q3 deployment runbook. Can you take a look before we share it with the wider team? I'd especially appreciate feedback on the rollback procedures section. No rush — by end of week is fine.",
    },
    {
        "id": 5,
        "from": "support@softwarelicense.com",
        "subject": "Your license expires in 7 days",
        "body": "Reminder: Your enterprise license for SecureVault Pro expires on June 20, 2026. To avoid service interruption, please renew before the expiry date. Contact your account manager or visit our portal to renew.",
    },
    {
        "id": 6,
        "from": "ceo@bigclient.com",
        "subject": "Urgent: Need proposal by tomorrow morning",
        "body": "We've moved our board meeting forward to Wednesday. I need the revised commercial proposal on the table by 9am tomorrow at the latest. This is a €500k deal and timing is critical. Please confirm receipt of this message.",
    },
]

SYSTEM_PROMPT = """You are an intelligent email triage agent for a busy professional.

For each email, you MUST respond with ONLY a valid JSON object (no markdown, no explanation) in this exact format:
{
  "urgency": "High" | "Medium" | "Low",
  "category": "Client Issue" | "Internal Request" | "Scheduling" | "Newsletter/Spam" | "License/Admin" | "Sales/Commercial",
  "route_to": "Finance" | "HR" | "Management" | "IT" | "Sales" | "Self" | "Archive",
  "summary": "One sentence summary of what this email is about.",
  "draft_reply": "A professional, concise reply ready to send. 2-4 sentences max.",
  "action": "What the recipient should do next, in one sentence."
}

Be direct and professional. Draft replies should sound human, not robotic."""

class EmailRequest(BaseModel):
    emails: List[dict]

@app.get("/")
async def root():
    return FileResponse("static/index.html")

@app.get("/api/sample-emails")
async def get_sample_emails():
    return SAMPLE_EMAILS

@app.post("/api/triage/stream")
async def triage_stream(request: EmailRequest):
    async def generate():
        for email in request.emails:
            prompt = f"""Triage this email:

From: {email['from']}
Subject: {email['subject']}
Body: {email['body']}"""

            try:
                response = client.chat.completions.create(
                    model=DEPLOYMENT,
                    messages=[
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": prompt},
                    ],
                    max_tokens=400,
                    temperature=0.2,
                )
                result_text = response.choices[0].message.content.strip()
                result_json = json.loads(result_text)
                result_json["email_id"] = email["id"]
                result_json["from"] = email["from"]
                result_json["subject"] = email["subject"]
                yield f"data: {json.dumps(result_json)}\n\n"
            except Exception as e:
                error_payload = {
                    "email_id": email.get("id"),
                    "error": str(e),
                    "subject": email.get("subject", "Unknown"),
                }
                yield f"data: {json.dumps(error_payload)}\n\n"

            await asyncio.sleep(0.1)

        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")

@app.get("/health")
async def health():
    return {"status": "ok", "model": DEPLOYMENT}
