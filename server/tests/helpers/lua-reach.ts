import fs from 'node:fs';
import path from 'node:path';

export type DevelopAccess = 'reads' | 'writes' | 'session';

interface Token {
  kind: 'name' | 'string' | 'other';
  text: string;
  column: number;
}

interface Chunk {
  node: string;
  tokens: Token[];
}

const LONG_BRACKET = /^\[(=*)\[/;
const NOT_STATEMENT_START = new Set(['end', 'else', 'elseif', 'until', '}', ')', ']']);
const DEVELOP_READS = new Set(['getDevelopSettings', 'getDevelopSnapshots']);
const DEVELOP_WRITES = new Set([
  'applyDevelopSettings',
  'applyDevelopPreset',
  'createDevelopSnapshot',
  'applyDevelopSnapshot',
  'deleteDevelopSnapshot',
  'updateAISettings',
  'deleteAllEmptyMasks',
  'quickDevelopSetTreatment',
  'createVirtualCopies',
]);
const SESSION = 'DevelopSession.run';
const CONTROLLER_WRITE = 'CatalogWrite.develop';

function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let index = 0;
  let lineStart = 0;
  const longClose = (level: string, from: number) => {
    const close = source.indexOf(`]${level}]`, from);
    return close < 0 ? source.length : close + level.length + 2;
  };
  const advanceTo = (end: number) => {
    for (let at = index; at < end; at++) if (source[at] === '\n') lineStart = at + 1;
    index = end;
  };
  while (index < source.length) {
    const char = source[index];
    const column = index - lineStart;
    if (char === '\n') {
      index++;
      lineStart = index;
      continue;
    }
    if (/\s/.test(char)) {
      index++;
      continue;
    }
    if (source.startsWith('--', index)) {
      const long = LONG_BRACKET.exec(source.slice(index + 2));
      const end = long ? longClose(long[1], index + 2 + long[0].length) : source.indexOf('\n', index);
      advanceTo(end < 0 ? source.length : end);
      continue;
    }
    const long = char === '[' ? LONG_BRACKET.exec(source.slice(index)) : null;
    if (long) {
      const end = longClose(long[1], index + long[0].length);
      tokens.push({ kind: 'string', text: source.slice(index + long[0].length, end - long[1].length - 2), column });
      advanceTo(end);
      continue;
    }
    if (char === '"' || char === "'") {
      let end = index + 1;
      while (end < source.length && source[end] !== char) end += source[end] === '\\' ? 2 : 1;
      tokens.push({ kind: 'string', text: source.slice(index + 1, end), column });
      advanceTo(end + 1);
      continue;
    }
    const name = /^[A-Za-z_][A-Za-z0-9_]*/.exec(source.slice(index, index + 200));
    if (name) {
      tokens.push({ kind: 'name', text: name[0], column });
      index += name[0].length;
      continue;
    }
    tokens.push({ kind: 'other', text: char, column });
    index++;
  }
  return tokens;
}

function statements(tokens: Token[]): Token[][] {
  const found: Token[][] = [];
  for (const token of tokens) {
    const starts = token.column === 0 && token.kind !== 'string' && !NOT_STATEMENT_START.has(token.text);
    if (starts || found.length === 0) found.push([]);
    found[found.length - 1].push(token);
  }
  return found;
}

function definedName(statement: Token[]): string | null {
  const texts = statement.slice(0, 5).map((token) => token.text);
  if (texts[0] === 'local' && texts[1] === 'function') return texts[2];
  if (texts[0] === 'function') return texts[2] === '.' || texts[2] === ':' ? `${texts[1]}.${texts[3]}` : texts[1];
  if (texts[0] === 'local') return texts[1];
  if (texts[1] === '.' && texts[3] === '=') return `${texts[0]}.${texts[2]}`;
  if (texts[1] === '=') return texts[0];
  return null;
}

interface Module {
  file: string;
  table: string | null;
  requires: Map<string, string>;
  chunks: Chunk[];
  locals: Set<string>;
}

function readModule(file: string, source: string): Module {
  const tokens = tokenize(source);
  const requires = new Map<string, string>();
  tokens.forEach((token, at) => {
    if (token.text !== 'require' || tokens[at - 1]?.text !== '=') return;
    const literal = tokens[at + 1]?.kind === 'string' ? tokens[at + 1] : tokens[at + 2];
    if (literal?.kind === 'string') requires.set(tokens[at - 2].text, literal.text);
  });
  const returned = [...tokens].reverse().findIndex((token) => token.text === 'return' && token.column === 0);
  const table = returned < 0 ? null : (tokens[tokens.length - returned]?.text ?? null);
  const chunks: Chunk[] = [];
  const locals = new Set<string>();
  for (const statement of statements(tokens)) {
    const name = definedName(statement);
    if (name === null) continue;
    const [owner, field] = name.split('.');
    const node =
      field !== undefined && owner === table ? `${file}.${field}` : `${file}:${field === undefined ? name : owner}`;
    if (field === undefined || owner !== table) locals.add(field === undefined ? name : owner);
    chunks.push({ node, tokens: statement });
  }
  return { file, table, requires, chunks, locals };
}

interface Graph {
  nodes: Set<string>;
  edges: Map<string, Set<string>>;
  access: Map<string, Set<DevelopAccess>>;
}

function addTo<T>(map: Map<string, Set<T>>, key: string, value: T) {
  const set = map.get(key) ?? new Set<T>();
  set.add(value);
  map.set(key, set);
}

function graphOf(modules: Module[]): Graph {
  const nodes = new Set(modules.flatMap((module) => module.chunks.map((chunk) => chunk.node)));
  const edges = new Map<string, Set<string>>();
  const access = new Map<string, Set<DevelopAccess>>();
  for (const module of modules) {
    const resolve = (owner: string, field: string | undefined): string | null => {
      if (field !== undefined && module.requires.has(owner)) return `${module.requires.get(owner)}.${field}`;
      if (field !== undefined && owner === module.table) return `${module.file}.${field}`;
      return module.locals.has(owner) ? `${module.file}:${owner}` : null;
    };
    for (const { node, tokens } of module.chunks) {
      tokens.forEach((token, at) => {
        const before = tokens[at - 1]?.text;
        if (token.kind === 'string' || before === '.' || before === ':') {
          if (DEVELOP_WRITES.has(token.text)) addTo(access, node, 'writes');
          if (before === ':' && DEVELOP_READS.has(token.text)) addTo(access, node, 'reads');
          return;
        }
        if (token.kind !== 'name') return;
        const field = tokens[at + 1]?.text === '.' && tokens[at + 2]?.kind === 'name' ? tokens[at + 2].text : undefined;
        if (token.text === 'LrUndo' && field === 'undo') addTo(access, node, 'writes');
        const target = resolve(token.text, field);
        if (target === null || target === node) return;
        addTo(edges, node, target);
        if (target === SESSION) addTo(access, node, 'session');
        if (target === CONTROLLER_WRITE) addTo(access, node, 'writes');
      });
    }
  }
  return { nodes, edges, access };
}

export interface DevelopAccessScan {
  accessOf: (handler: string) => Set<DevelopAccess>;
  defines: (handler: string) => boolean;
}

export function developAccessByHandler(pluginDir: string): DevelopAccessScan {
  const modules = fs
    .readdirSync(pluginDir)
    .filter((name) => name.endsWith('.lua') && name !== 'Contract.lua')
    .map((name) => readModule(path.basename(name, '.lua'), fs.readFileSync(path.join(pluginDir, name), 'utf8')));
  const { nodes, edges, access } = graphOf(modules);
  const accessOf = (handler: string) => {
    const reached = new Set<DevelopAccess>();
    const seen = new Set<string>([handler]);
    const queue = [handler];
    while (queue.length) {
      const node = queue.pop()!;
      for (const kind of access.get(node) ?? []) reached.add(kind);
      for (const next of edges.get(node) ?? []) {
        if (!seen.has(next)) {
          seen.add(next);
          queue.push(next);
        }
      }
    }
    return reached;
  };
  return { accessOf, defines: (handler) => nodes.has(handler) };
}
