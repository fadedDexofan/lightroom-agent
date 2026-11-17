interface WithContent {
  content: unknown;
}

export function envelopeOf(response: WithContent): Record<string, unknown> & { outcome: string } {
  const [first] = response.content as Array<{ text: string }>;
  return JSON.parse(first.text) as Record<string, unknown> & { outcome: string };
}

export function dataOf(response: WithContent): unknown {
  return envelopeOf(response).data;
}
