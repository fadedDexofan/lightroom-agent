import { TOOL_CONTRACTS } from "./tool-contracts.js";

const FIRST_SENTENCE = /^(.+?[.!?])(?:\s|$)/s;

export function manifestTools(): { name: string; description: string }[] {
  return TOOL_CONTRACTS.map(({ name, description }) => ({ name, description: FIRST_SENTENCE.exec(description)?.[1] ?? description }));
}
