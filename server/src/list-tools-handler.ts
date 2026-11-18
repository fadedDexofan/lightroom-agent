import type { Tool } from "@modelcontextprotocol/server";
import type { Toolset } from "./toolsets.js";
import { TOOL_CONTRACTS, type ToolContract } from "./tool-contracts.js";

const DEVELOP_READ_SENTENCE = "Opens the photo in Develop, then restores module, source and selection; runs one at a time"
  + " with other Develop calls, and commits any slider change the user is making in Develop at that moment.";
const DEVELOP_STATE_READ_SENTENCE = "Waits for the Develop calls before it, across every client; fails without effect"
  + " if its turn does not come within its time budget.";

export function publishedDescription(
  { description, rules, develop, annotations }: Pick<ToolContract, "description" | "rules" | "develop" | "annotations">,
): string {
  const developNote = develop === "reads" ? ` ${DEVELOP_STATE_READ_SENTENCE}`
    : develop === "drives" && annotations.readOnlyHint ? ` ${DEVELOP_READ_SENTENCE}` : "";
  const ruleNote = rules?.length ? ` Rules: ${rules.map((rule) => rule.text).join("; ")}.` : "";
  return `${description}${developNote}${ruleNote}`;
}

export const TOOL_DEFINITIONS: Tool[] = TOOL_CONTRACTS.map((contract) => ({
  name: contract.name,
  title: contract.title,
  annotations: contract.annotations,
  description: publishedDescription(contract),
  inputSchema: contract.inputSchema,
  ...(contract.alwaysLoad ? { _meta: { "anthropic/alwaysLoad": true } } : {}),
}));

export function listToolsHandler(toolsets: ReadonlySet<Toolset>, readOnly: boolean): { tools: Tool[] } {
  return { tools: TOOL_DEFINITIONS.filter((_tool, index) => {
    const contract = TOOL_CONTRACTS[index];
    return toolsets.has(contract.toolset) && (!readOnly || contract.annotations.readOnlyHint === true);
  }) };
}
