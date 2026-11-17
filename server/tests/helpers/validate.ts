import { TOOL_CONTRACTS, type ToolArgs } from '../../src/tool-contracts.js';
import { validateToolArgs as validateContractArgs } from '../../src/validate-args.js';

export function validateToolArgs(name: string, args: unknown): string | null {
  const contract = TOOL_CONTRACTS.find((candidate) => candidate.name === name);
  if (!contract) throw new Error(`no contract named ${name}`);
  return validateContractArgs(contract, (args ?? {}) as ToolArgs);
}
