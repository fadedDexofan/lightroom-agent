import type { ToolArgs } from '../../src/tool-contracts.js';
import { CHECKED_CONTRACTS, validateToolArgs as validateContractArgs } from '../../src/validate-args.js';

export function validateToolArgs(name: string, args: unknown): string | null {
  const checked = CHECKED_CONTRACTS.get(name);
  if (!checked) throw new Error(`no contract named ${name}`);
  return validateContractArgs(checked, args as ToolArgs);
}
