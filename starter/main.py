"""
Customer Support AI Agent — Starter Code
==========================================
Your task is to complete this file by implementing all sections marked
with # TODO comments.

Reference the project instructions and rubric for guidance.
Work through each section yourself.

Run locally (after filling in config values):
  uv run main.py '{"prompt": "Hello", "customer_id": "CUST-123", "session_id": "s1"}'

Deploy to AgentCore:
  agentcore deploy

Invoke deployed agent:
  agentcore invoke '{"prompt": "Hello", "customer_id": "CUST-123", "session_id": "s1"}'
"""

# ── Imports ───────────────────────────────────────────────────────────────────
# These imports are provided. Do not remove them.
from strands import Agent, tool
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.memory import MemoryClient
from strands.models import BedrockModel
from strands.tools.mcp.mcp_client import MCPClient
from mcp.client.streamable_http import streamable_http_client
import argparse, json
import os, asyncio, boto3
from strands.hooks import (
    HookProvider, AfterInvocationEvent, HookRegistry, MessageAddedEvent,
    AfterToolCallEvent,
)
import logging
import uuid
from typing import Dict
from bedrock_agentcore.tools.code_interpreter_client import code_session
from strands_tools.browser import AgentCoreBrowser


logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger("CSAI_Agent")

# ── TODO 1 — App Initialisation ───────────────────────────────────────────────
# Create a BedrockAgentCoreApp instance.
# This registers the ASGI server for AgentCore deployment.
# There must be exactly one instance per deployment.
#
# Hint: app = BedrockAgentCoreApp()

app = BedrockAgentCoreApp()


# Suppress interactive tool-consent prompts (required in headless deployments).
os.environ["BYPASS_TOOL_CONSENT"] = "true"


# ── TODO 2 — Configuration ────────────────────────────────────────────────────
# Replace the placeholder strings with your actual AWS resource values.
# You collected these in the infrastructure setup section of the project instructions.
#
# GATEWAY_URL format: https://<alias>.gateway.bedrock-agentcore.<region>.amazonaws.com/mcp
# This starter uses an unsigned MCP connection and therefore assumes the
# project Gateway is configured with the NONE authorizer.
# KB_ID       format: 10-character alphanumeric string from the KB console
# REGION:     your AWS region, e.g. "us-east-1"
# MEMORY_ID   format: shown in the AgentCore Memory console

GATEWAY_URL = "https://customersupportgateway-nujtlaadku.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp"
KB_ID       = "IUPTCE7YRR"
REGION      = "us-east-1"
MEMORY_ID   = "CustomerSupportMemory-MpfCY7AqJ3"


# ── TODO 3 — Model and Clients ────────────────────────────────────────────────
# Create:
#   1. A BedrockModel using model_id "global.amazon.nova-2-lite-v1:0"
#   2. A MemoryClient with region_name=REGION
#   3. A boto3 client for the "bedrock-agent-runtime" service in REGION
#
# Hint: model = BedrockModel(model_id=model_id)

model_id = "global.amazon.nova-2-lite-v1:0"

model = BedrockModel(model_id=model_id, region_name=REGION)

memory_client = MemoryClient(region_name=REGION)

_bedrock_runtime = boto3.client("bedrock-agent-runtime", region_name=REGION)


# ── TODO 4 — Namespace Helper ─────────────────────────────────────────────────
# Implement get_namespaces() to return a dict mapping strategy type to
# namespace template string.
#
# Steps:
#   1. Call mem_client.get_memory_strategies(memory_id) to get strategy list
#   2. Read the namespace from strategy["namespaceTemplates"][0].
#      For compatibility with older AgentCore responses, fall back to
#      strategy["namespaces"][0] when namespaceTemplates is absent.
#
# Example output:
#   { "SEMANTIC": "cs_agent/{actorId}/facts",
#     "USER_PREFERENCE": "cs_agent/{actorId}/preferences" }

def get_namespaces(mem_client: MemoryClient, memory_id: str) -> Dict:
    """Return a dict mapping strategy type → namespace template string."""
    namespaces = {}
    for strategy in mem_client.get_memory_strategies(memory_id):
        strategy_type = strategy.get("type") or strategy.get("memoryStrategyType")
        # namespaceTemplates is current; namespaces is the legacy field.
        templates = strategy.get("namespaceTemplates") or strategy.get("namespaces") or []
        if strategy_type and templates:
            namespaces[strategy_type] = templates[0]
    return namespaces


# ── TODO 5 — Memory Hook ──────────────────────────────────────────────────────
# Implement MemoryHook, a HookProvider subclass that adds long-term memory.
#
# The class needs:
#   __init__(self, actor_id, session_id, memory_client, memory_id)
#     — store all four as instance attributes
#     — call get_namespaces() and store the result as self.namespaces
#
#   retrieve_customer_context(self, event: MessageAddedEvent)
#     — only runs for plain-text user messages (not tool results)
#     — for each strategy namespace, call memory_client.retrieve_memories(
#          memory_id, namespace (formatted with actorId), query, top_k=5)
#     — collect non-empty memory texts tagged with their strategy type
#     — if any memories found, prepend them to the user message as:
#          "Customer Context:\n<memories>\n\n<original_message>"
#
#   save_support_interaction(self, event: AfterInvocationEvent)
#     — walk the message list backwards to find the last plain-text user
#       query and the last assistant response
#     — call memory_client.create_event(memory_id, actor_id, session_id,
#          messages=[(customer_query, "USER"), (agent_response, "ASSISTANT")])
#
#   register_hooks(self, registry: HookRegistry)
#     — register retrieve_customer_context on MessageAddedEvent
#     — register save_support_interaction on AfterInvocationEvent

class MemoryHook(HookProvider):
    """Long-term memory hook for the customer support agent."""

    def __init__(
        self,
        actor_id: str,
        session_id: str,
        memory_client: MemoryClient,
        memory_id: str,
    ):
        self.actor_id = actor_id
        self.session_id = session_id
        self.memory_id = memory_id
        self.memory_client = memory_client
        self.namespaces = get_namespaces(memory_client, memory_id)
        # The user message is rewritten with retrieved context before the model
        # sees it; keep the original so only the customer's own words are saved.
        self._original_query = None

    @staticmethod
    def _text_of(message: dict) -> str:
        """Join the text blocks of a message ("" if it has none)."""
        return "\n".join(
            block["text"] for block in message.get("content", []) if "text" in block
        ).strip()

    def retrieve_customer_context(self, event: MessageAddedEvent):
        """Retrieve relevant memories and prepend them to the user message."""
        messages = event.agent.messages
        if not messages or messages[-1]["role"] != "user":
            return
        last = messages[-1]
        # Tool results are also added as user messages; skip them.
        if any("toolResult" in block for block in last["content"]):
            return
        user_query = self._text_of(last)
        if not user_query:
            return
        self._original_query = user_query

        try:
            context = []
            for strategy_type, template in self.namespaces.items():
                namespace = template.replace("{actorId}", self.actor_id)
                memories = self.memory_client.retrieve_memories(
                    memory_id=self.memory_id,
                    namespace=namespace,
                    query=user_query,
                    top_k=5,
                )
                for memory in memories:
                    text = memory.get("content", {}).get("text", "").strip()
                    if text:
                        context.append(f"[{strategy_type}] {text}")

            if context:
                last["content"] = [{
                    "text": "Customer Context:\n" + "\n".join(context)
                            + f"\n\n{user_query}"
                }] + [block for block in last["content"] if "text" not in block]
                logger.info("Added %d memories to the user message", len(context))
        except Exception as e:
            # Memory is an enhancement; never fail the customer's request over it.
            logger.warning("Memory retrieval failed: %s", e)

    def save_support_interaction(self, event: AfterInvocationEvent):
        """Save the completed turn to memory after the agent responds."""
        customer_query, agent_response = None, None
        for message in reversed(event.agent.messages):
            text = self._text_of(message)
            if not text:
                continue
            if message["role"] == "assistant" and agent_response is None:
                agent_response = text
            elif (message["role"] == "user" and agent_response is not None
                  and not any("toolResult" in b for b in message["content"])):
                customer_query = text
                break

        if not customer_query or not agent_response:
            return
        # Save what the customer typed, not the context-augmented version.
        if customer_query.startswith("Customer Context:") and self._original_query:
            customer_query = self._original_query

        try:
            self.memory_client.create_event(
                memory_id=self.memory_id,
                actor_id=self.actor_id,
                session_id=self.session_id,
                messages=[(customer_query, "USER"), (agent_response, "ASSISTANT")],
            )
        except Exception as e:
            logger.warning("Memory save failed: %s", e)

    def register_hooks(self, registry: HookRegistry) -> None:  # type: ignore
        """Register both memory callbacks."""
        registry.add_callback(MessageAddedEvent, self.retrieve_customer_context)
        registry.add_callback(AfterInvocationEvent, self.save_support_interaction)


class ToolCallLogger(HookProvider):
    """Log every tool call (name, input, status, result preview) to the runtime logs.

    Lines are tagged with the session ID so one conversation's tool calls can be
    pulled from CloudWatch, e.g. filter pattern '"[session t1] TOOL"'.
    """

    def __init__(self, session_id: str, preview_chars: int = 600):
        self.session_id = session_id
        self.preview_chars = preview_chars

    def log_tool_call(self, event: AfterToolCallEvent):
        result = event.result or {}
        text = " ".join(
            block["text"] for block in result.get("content", []) if "text" in block
        )
        if len(text) > self.preview_chars:
            text = text[: self.preview_chars] + "…"
        print(
            f"[session {self.session_id}] TOOL {event.tool_use['name']} "
            f"input={json.dumps(event.tool_use.get('input', {}))} "
            f"status={result.get('status', 'unknown')} result={text}",
            flush=True,
        )

    def register_hooks(self, registry: HookRegistry) -> None:  # type: ignore
        registry.add_callback(AfterToolCallEvent, self.log_tool_call)


# ── TODO 6 — Knowledge Base Tool ─────────────────────────────────────────────
# Implement search_knowledge_base(query) using the @tool decorator.
#
# Steps:
#   1. Guard: if KB_ID is empty return "Knowledge base not configured."
#   2. Call _bedrock_runtime.retrieve(
#          knowledgeBaseId=KB_ID,
#          retrievalQuery={"text": query}
#      )
#   3. Extract resp["retrievalResults"]; return a message if empty
#   4. Join the text chunks with "\n---\n" and return the result
#
# The docstring is the tool description — the model uses it to decide when
# to call this tool, so keep it clear and accurate.

@tool
def search_knowledge_base(query: str) -> str:
    """
    Search the Amazon product catalog and support knowledge base.
    Use this for product specifications, return policies, warranty
    information, loyalty program details, and order status definitions.

    Args:
        query: The question or topic to search for

    Returns:
        Relevant information retrieved from the knowledge base
    """
    if not KB_ID:
        return "Knowledge base not configured."
    try:
        resp = _bedrock_runtime.retrieve(
            knowledgeBaseId=KB_ID,
            retrievalQuery={"text": query},
        )
    except Exception as e:
        logger.error("Knowledge base retrieval failed: %s", e)
        return f"Knowledge base search failed: {e}"

    results = resp.get("retrievalResults", [])
    if not results:
        return "No relevant information found in the knowledge base."
    return "\n---\n".join(
        r["content"]["text"] for r in results if r.get("content", {}).get("text")
    )


# ── TODO 7 — Loyalty Discount Tool (Code Interpreter) ────────────────────────
# Implement calculate_loyalty_discount() using the @tool decorator.
#
# The tool must:
#   1. Build a self-contained Python code string that:
#        • Defines earn_rates: {"standard": 1, "device": 2, "fresh": 5}
#        • Defines tier_rates: {"Silver": 0.00, "Gold": 0.10, "Platinum": 0.15}
#        • Calculates points_redeemed (floor to nearest 500, cap at 50% of order)
#        • Calculates tier_discount (applied to subtotal after points)
#        • Calculates final_total, total_savings, points_earned, remaining_points
#        • Prints a JSON result dict
#   2. Execute the code with code_session(REGION).invoke("executeCode", {...})
#      using language="python" and clearContext=True
#   3. Return the first result event as a JSON string
#   4. Include a fallback that computes only the tier discount if the
#      Code Interpreter is unavailable

@tool
def calculate_loyalty_discount(
    loyalty_points: int,
    tier: str,
    order_total: float,
    product_category: str = "standard",
) -> str:
    """
    Calculate the loyalty discount for a customer order using the
    AgentCore Code Interpreter. Runs exact arithmetic in a secure sandbox.

    Args:
        loyalty_points:   Customer's current points balance
        tier:             Customer tier — Silver, Gold, or Platinum
        order_total:      Order total in USD
        product_category: standard, device, or fresh

    Returns:
        Full discount breakdown and final price
    """
    tier = tier.strip().capitalize()
    product_category = product_category.strip().lower()

    # Rules from the loyalty program: 100 points = $1, redeemed in blocks of
    # 500 (the minimum), covering at most 50% of the order. The tier discount
    # applies to the subtotal left after points.
    code = f"""
import json, math

earn_rates = {{"standard": 1, "device": 2, "fresh": 5}}
tier_rates = {{"Silver": 0.00, "Gold": 0.10, "Platinum": 0.15}}

loyalty_points = {int(loyalty_points)}
tier = {tier!r}
order_total = {float(order_total)!r}
product_category = {product_category!r}

max_points_for_order = int(order_total * 0.5 * 100)
points_redeemed = (min(loyalty_points, max_points_for_order) // 500) * 500
points_discount = points_redeemed / 100

subtotal = order_total - points_discount
tier_rate = tier_rates.get(tier, 0.0)
tier_discount = round(subtotal * tier_rate, 2)
final_total = round(subtotal - tier_discount, 2)
total_savings = round(points_discount + tier_discount, 2)
points_earned = math.floor(final_total * earn_rates.get(product_category, 1))
remaining_points = loyalty_points - points_redeemed

print(json.dumps({{
    "tier": tier,
    "product_category": product_category,
    "order_total": round(order_total, 2),
    "points_redeemed": points_redeemed,
    "points_discount": round(points_discount, 2),
    "subtotal_after_points": round(subtotal, 2),
    "tier_discount_pct": round(tier_rate * 100),
    "tier_discount": tier_discount,
    "final_total": final_total,
    "total_savings": total_savings,
    "points_earned": points_earned,
    "remaining_points": remaining_points,
    "new_points_balance": remaining_points + points_earned,
}}))
"""

    try:
        with code_session(REGION) as client:
            response = client.invoke("executeCode", {
                "code": code,
                "language": "python",
                "clearContext": True,
            })
            for event in response["stream"]:
                result = event.get("result")
                if result:
                    if result.get("isError"):
                        raise RuntimeError(json.dumps(result))
                    # The sandbox's stdout is the JSON printed by the code above;
                    # return it as-is so the fields are top level.
                    stdout = result.get("structuredContent", {}).get("stdout", "").strip()
                    return stdout if stdout else json.dumps(result)
        raise RuntimeError("Code Interpreter returned no result")

    except Exception as e:
        logger.warning("Code Interpreter unavailable, using fallback: %s", e)
        tier_rate = {"Silver": 0.00, "Gold": 0.10, "Platinum": 0.15}.get(tier, 0.0)
        tier_discount = round(order_total * tier_rate, 2)
        return json.dumps({
            "tier": tier,
            "order_total": round(order_total, 2),
            "points_redeemed": 0,
            "tier_discount_pct": round(tier_rate * 100),
            "tier_discount": tier_discount,
            "final_total": round(order_total - tier_discount, 2),
            "remaining_points": int(loyalty_points),
            "note": "Code Interpreter unavailable: only the tier discount was "
                    "applied and no points were redeemed.",
        })


# ── TODO 8 — Agent Entrypoint ─────────────────────────────────────────────────
# Implement the invoke() function decorated with @app.entrypoint.
#
# Steps:
#   1. Extract user_input, actor_id, and session_id from the payload
#      (generate a UUID if session_id is missing)
#   2. Instantiate MemoryHook for this actor/session
#   3. Instantiate AgentCoreBrowser(region=REGION)
#   4. Build the tools list: [search_knowledge_base, calculate_loyalty_discount,
#                              agent_core_browser.browser]
#   5. Connect to the Gateway via MCPClient, load gateway_tools, extend tools list
#   6. Create and invoke the Agent with all tools, hooks, and system_prompt
#   7. Return the text from the first content block of the response
#   8. Handle exceptions gracefully

SYSTEM_PROMPT = """You are a friendly, efficient customer support agent for an Amazon store.
The customer you are helping has customer ID: {customer_id}.

Use your tools instead of guessing, and never invent order details, prices or policies:
- Orders and customer profile: use the order tools (get_order, get_customer_orders,
  get_customer). If the customer has no order ID, list their orders first.
- Refunds and returns: confirm the order with get_order, then use initiate_refund
  (always include a short reason; include the amount when known), get_return_label
  or check_refund_status. After initiating a refund, always tell the customer the
  refund ID, its status and when the money will arrive.
- Products, return windows, warranties, refund timelines, loyalty tiers and order
  status meanings: use search_knowledge_base and answer from what it returns.
- Loyalty discounts: get the customer's points and tier with get_customer when you do
  not already have them, then use calculate_loyalty_discount. Never do the maths yourself.
- Live web information or a specific URL: use the browser tool. Session names must be
  10-36 characters of lowercase letters, digits and hyphens only (e.g. "web-session-1").
  If navigate times out, the page has usually loaded anyway: read it with get_text
  before trying to navigate again.

A user message may start with "Customer Context:" followed by what you remember about
this customer from earlier conversations. Always apply their name and communication
preferences. Use the other remembered facts only when they help with the current
request: do not bring up unrelated past orders or refunds unless the customer asks,
and do not read the context back verbatim.

Report tool results accurately, including IDs such as tracking numbers and refund IDs.
If a tool returns an error, say so plainly and suggest a next step.
Keep answers clear and concise, and follow any communication preference the customer
has expressed."""


@app.entrypoint
async def invoke(payload, context=None):
    """
    Main handler called by AgentCore for every incoming request.

    Expected payload keys:
      prompt      (str, required) — the customer's message
      customer_id (str, optional) — unique customer identifier
      session_id  (str, optional) — session identifier; generated if absent
    """
    user_input = payload.get("prompt", "").strip()
    if not user_input:
        return "Please include a prompt in your request."
    actor_id = payload.get("customer_id") or "anonymous"
    session_id = (
        payload.get("session_id")
        or getattr(context, "session_id", None)
        or str(uuid.uuid4())
    )

    agent_core_browser = None
    try:
        memory_hook = MemoryHook(actor_id, session_id, memory_client, MEMORY_ID)
        agent_core_browser = AgentCoreBrowser(region=REGION)

        tools = [search_knowledge_base, calculate_loyalty_discount,
                 agent_core_browser.browser]

        # Unsigned MCP connection: the Gateway uses the NONE authorizer.
        mcp_client = MCPClient(lambda: streamable_http_client(GATEWAY_URL))
        with mcp_client:
            gateway_tools = mcp_client.list_tools_sync()
            tools.extend(gateway_tools)

            agent = Agent(
                model=model,
                tools=tools,
                hooks=[memory_hook, ToolCallLogger(session_id)],
                system_prompt=SYSTEM_PROMPT.format(customer_id=actor_id),
            )
            response = await agent.invoke_async(user_input)

        return next(
            (block["text"] for block in response.message["content"] if "text" in block),
            "",
        )

    except Exception as e:
        logger.exception("Agent invocation failed")
        return f"Sorry, something went wrong while handling your request: {e}"

    finally:
        if agent_core_browser is not None:
            agent_core_browser.close_platform()


# ── CLI entry point (do not modify) ──────────────────────────────────────────
def main():
    """Run one invocation from the command line for local testing."""
    parser = argparse.ArgumentParser()
    parser.add_argument("payload", type=str)
    args = parser.parse_args()
    response = asyncio.run(invoke(json.loads(args.payload)))
    print(response)


if __name__ == "__main__":
    app.run()
    # Uncomment the line below and comment app.run() for local CLI testing:
    # main()
