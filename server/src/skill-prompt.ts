import { ProtocolError, ProtocolErrorCode } from '@modelcontextprotocol/server';
import { SKILL_PROMPT, SKILL_TEXT } from './skill-content.js';

export function getSkillPrompt(name: string) {
  if (name !== SKILL_PROMPT.name) {
    throw new ProtocolError(ProtocolErrorCode.InvalidParams, `Unknown prompt: ${name}`);
  }
  return {
    description: SKILL_PROMPT.description,
    messages: [{ role: 'user' as const, content: { type: 'text' as const, text: SKILL_TEXT } }],
  };
}
