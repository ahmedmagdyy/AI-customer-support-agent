# Reflection

## Design decision: saving the customer's own words to memory

My `MemoryHook` for AgentCore Memory puts recalled facts in front of each user message ("Customer Context: …") so the model can personalise its answer. When the turn is saved, however, the hook stores the customer's original message, not the augmented one. Saving the augmented version would write the recalled facts back into memory on every turn, so memory would fill with duplicates that reinforce themselves over time. Saving the original keeps each event an accurate record of what the customer actually said.

## Challenge: tools the model could not tell apart

After adding the API Gateway target, MCP Inspector showed that the three order tools had descriptions identical to their names (for example "get_order"), because the summaries in my OpenAPI definition were not carried into the Gateway. The model chooses tools largely from their descriptions, so this made tool selection unreliable. I fixed it with Gateway tool overrides that say, for each tool, when to use it, the input format, what it returns and which tool to use instead. Local testing before deployment then exposed two prompt problems: the refund answer left out the refund ID, and remembered facts were brought up unprompted. I tightened the system prompt for both and re-tested before deploying.

## Extending the agent for production

- **Authentication:** replace the Gateway's NONE authorizer with a JWT authorizer such as Amazon Cognito, use IAM authorization on the API Gateway methods, and take the customer ID from the verified token instead of the request payload, so one customer cannot read another customer's orders or memories.
- **Real data and safe actions:** back the Lambda functions with DynamoDB and the real order system, and require confirmation or human approval for refunds above a set amount.
- **Safety and quality:** add Amazon Bedrock Guardrails, run an evaluation suite on every change, and turn on tracing (deployment warned that X-Ray delivery was not configured) with CloudWatch alarms.
- **Operations:** define every resource in CloudFormation or CDK instead of setup scripts, set retention and PII rules for memory, and reduce each IAM role to least privilege.
