import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { parse, type AnyNode, type CallExpression, type Identifier, type ObjectExpression, type Pattern } from 'acorn';
import { PHOTO_ID_PATTERN, type ToolArgs } from '../src/tool-contracts.js';
import { CHECKED_CONTRACTS, validateToolArgs } from '../src/validate-args.js';

const KIT = path.resolve(process.cwd(), '..', 'tests', 'e2e');
const CALLERS = new Set(['tool', 'toolOrThrow', 'callTool', 'toolData', 'data', 'answer']);
const HOLE = Symbol('hole');
const STAND_IN_ID = '1';

type Schema = {
  type?: string | string[];
  enum?: unknown[];
  const?: unknown;
  anyOf?: Schema[];
  oneOf?: Schema[];
  pattern?: string;
  minimum?: number;
  maximum?: number;
  exclusiveMinimum?: number;
  exclusiveMaximum?: number;
  minItems?: number;
  maxItems?: number;
  minProperties?: number;
  items?: Schema;
  properties?: Record<string, Schema>;
  required?: string[];
};

class Unreadable extends Error {}

interface Hole {
  [HOLE]: AnyNode;
}

type Value = unknown;

interface KitCall {
  where: string;
  tool: string;
  args: Value;
}

interface UnreadSite {
  where: string;
  file: string;
  tool: string;
  reason: string;
}

interface Scan {
  calls: KitCall[];
  unread: UnreadSite[];
  unknownTools: string[];
  otherCallers: string[];
}

type FunctionNode = Extract<
  AnyNode,
  { type: 'FunctionDeclaration' | 'FunctionExpression' | 'ArrowFunctionExpression' }
>;

const EXPRESSIONS = new Set([
  'Identifier',
  'Literal',
  'ThisExpression',
  'ArrayExpression',
  'ObjectExpression',
  'FunctionExpression',
  'UnaryExpression',
  'UpdateExpression',
  'BinaryExpression',
  'AssignmentExpression',
  'LogicalExpression',
  'MemberExpression',
  'ConditionalExpression',
  'CallExpression',
  'NewExpression',
  'SequenceExpression',
  'ArrowFunctionExpression',
  'YieldExpression',
  'TemplateLiteral',
  'TaggedTemplateExpression',
  'ClassExpression',
  'MetaProperty',
  'AwaitExpression',
  'ChainExpression',
  'ImportExpression',
  'ParenthesizedExpression',
]);

const hole = (expression: AnyNode): Hole => ({ [HOLE]: expression });
const isHole = (value: unknown): value is Hole => typeof value === 'object' && value !== null && HOLE in value;

const parents = new WeakMap<AnyNode, AnyNode>();

function childrenOf(node: AnyNode): AnyNode[] {
  const children = new Set<AnyNode>();
  for (const [key, value] of Object.entries(node)) {
    if (key === 'loc') continue;
    for (const item of Array.isArray(value) ? (value as unknown[]) : [value]) {
      if (typeof item === 'object' && item !== null && typeof (item as { type?: unknown }).type === 'string') {
        children.add(item as AnyNode);
      }
    }
  }
  return [...children].sort((a, b) => a.start - b.start);
}

function linkParents(node: AnyNode): void {
  for (const child of childrenOf(node)) {
    parents.set(child, node);
    linkParents(child);
  }
}

function rootOf(node: AnyNode): AnyNode {
  let root = node;
  for (let parent = parents.get(root); parent; parent = parents.get(root)) root = parent;
  return root;
}

const isIdentifier = (node: AnyNode | null | undefined): node is Identifier => node?.type === 'Identifier';
const isExpression = (node: AnyNode) => EXPRESSIONS.has(node.type);
const isFunction = (node: AnyNode | undefined): node is FunctionNode =>
  node?.type === 'FunctionDeclaration' ||
  node?.type === 'FunctionExpression' ||
  node?.type === 'ArrowFunctionExpression';

function stringText(node: AnyNode): string | undefined {
  if (node.type === 'Literal' && typeof node.value === 'string') return node.value;
  if (node.type === 'TemplateLiteral' && node.expressions.length === 0) return node.quasis[0].value.cooked ?? undefined;
  return undefined;
}

function boundName(pattern: Pattern | null): Identifier | undefined {
  if (!pattern) return undefined;
  if (pattern.type === 'Identifier') return pattern;
  if (pattern.type === 'AssignmentPattern') return boundName(pattern.left);
  if (pattern.type === 'RestElement') return boundName(pattern.argument);
  return undefined;
}

function elementsOf(pattern: Pattern): Pattern[] {
  if (pattern.type === 'ObjectPattern') {
    return pattern.properties.map((property) => (property.type === 'RestElement' ? property : property.value));
  }
  if (pattern.type === 'ArrayPattern') return pattern.elements.filter((element) => element !== null);
  return [];
}

function declaredIn(statements: readonly AnyNode[], name: string): AnyNode | undefined {
  for (const item of statements) {
    const statement =
      item.type === 'ExportNamedDeclaration' || item.type === 'ExportDefaultDeclaration' ? item.declaration : item;
    if (!statement) continue;
    if (statement.type === 'FunctionDeclaration' && statement.id?.name === name) return statement;
    if (statement.type !== 'VariableDeclaration') continue;
    for (const declaration of statement.declarations) {
      if (isIdentifier(declaration.id) && declaration.id.name === name) {
        return statement.kind === 'const' && declaration.init ? declaration.init : declaration;
      }
      if (
        !isIdentifier(declaration.id) &&
        elementsOf(declaration.id).some((element) => boundName(element)?.name === name)
      ) {
        return declaration;
      }
    }
  }
  return undefined;
}

function patternHolds(pattern: Pattern, name: string): boolean {
  if (pattern.type === 'Identifier') return pattern.name === name;
  if (pattern.type === 'AssignmentPattern') return patternHolds(pattern.left, name);
  if (pattern.type === 'RestElement') return patternHolds(pattern.argument, name);
  return elementsOf(pattern).some((element) => patternHolds(element, name));
}

function binding(identifier: Identifier): AnyNode | undefined {
  const name = identifier.name;
  for (let scope = parents.get(identifier); scope; scope = parents.get(scope)) {
    const statements =
      scope.type === 'BlockStatement' || scope.type === 'Program'
        ? scope.body
        : scope.type === 'SwitchCase'
          ? scope.consequent
          : undefined;
    if (statements) {
      const found = declaredIn(statements, name);
      if (found) return found;
    }
    if (isFunction(scope)) {
      const parameter = scope.params.find((item) => boundName(item)?.name === name);
      if (parameter) return parameter;
    }
    const initializer =
      scope.type === 'ForStatement'
        ? scope.init
        : scope.type === 'ForInStatement' || scope.type === 'ForOfStatement'
          ? scope.left
          : undefined;
    if (initializer?.type === 'VariableDeclaration') {
      const declared = initializer.declarations.find((item) => patternHolds(item.id, name));
      if (declared) return declared;
    }
    if (scope.type === 'CatchClause' && isIdentifier(scope.param) && scope.param.name === name) return scope;
  }
  return undefined;
}

function isParameter(node: AnyNode): boolean {
  const parent = parents.get(node);
  return isFunction(parent) && (parent.params as AnyNode[]).includes(node);
}

function returnedObject(node: AnyNode): AnyNode | undefined {
  if (!isFunction(node)) return undefined;
  const body = node.body;
  if (body.type !== 'BlockStatement') return body;
  const returns = body.body.filter((statement) => statement.type === 'ReturnStatement');
  return body.body.length === 1 && returns.length === 1 ? (returns[0].argument ?? undefined) : undefined;
}

function functionName(fn: FunctionNode): Identifier | undefined {
  if (fn.type === 'FunctionDeclaration') return fn.id ?? undefined;
  const parent = parents.get(fn);
  if (parent?.type === 'VariableDeclarator') return isIdentifier(parent.id) ? parent.id : undefined;
  return undefined;
}

function callsOf(fn: FunctionNode, name: Identifier): CallExpression[] {
  const calls: CallExpression[] = [];
  const visit = (node: AnyNode): void => {
    if (node.type === 'CallExpression' && isIdentifier(node.callee) && node.callee.name === name.name) {
      if (binding(node.callee) === fn) calls.push(node);
    }
    for (const child of childrenOf(node)) visit(child);
  };
  visit(rootOf(fn));
  return calls;
}

const MAX_VARIANTS = 64;
type ArgObject = Record<string, Value>;

function capped<T>(variants: T[]): T[] {
  if (variants.length > MAX_VARIANTS) throw new Unreadable('more argument variants than the gate reads');
  return variants;
}

const readableProperty = (property: AnyNode) =>
  property.type === 'SpreadElement' ||
  (property.type === 'Property' && property.kind === 'init' && !property.method && !property.computed);

function propertyName(key: AnyNode): string {
  if (isIdentifier(key)) return key.name;
  return String((key as { value?: unknown }).value);
}

class Reader {
  constructor(private readonly text: string) {}

  objects(expression: AnyNode, depth = 0): ArgObject[] {
    if (depth > 12) throw new Unreadable('nested too deep');
    if (expression.type === 'ParenthesizedExpression') return this.objects(expression.expression, depth + 1);
    if (expression.type === 'ObjectExpression') return this.objectLiteral(expression, depth);
    if (isIdentifier(expression)) return this.bound(expression, depth);
    if (expression.type === 'CallExpression' && isIdentifier(expression.callee)) {
      const bound = binding(expression.callee);
      const returned = bound && returnedObject(bound);
      if (returned) return this.objects(returned, depth + 1);
      throw new Unreadable(`${expression.callee.name}(…) does not return an object literal`);
    }
    if (expression.type === 'ConditionalExpression') {
      return capped([
        ...this.objects(expression.consequent, depth + 1),
        ...this.objects(expression.alternate, depth + 1),
      ]);
    }
    throw new Unreadable(`an argument object built by ${expression.type}`);
  }

  private bound(identifier: Identifier, depth: number): ArgObject[] {
    const bound = binding(identifier);
    if (bound && isParameter(bound)) return this.parameter(bound as Pattern, depth);
    if (
      bound &&
      isExpression(bound) &&
      bound.type !== 'ArrowFunctionExpression' &&
      bound.type !== 'FunctionExpression'
    ) {
      return this.objects(bound, depth + 1);
    }
    const elements = bound && this.loopElements(identifier.name, bound);
    if (elements) return capped(elements.flatMap((element) => this.objects(element, depth + 1)));
    throw new Unreadable(`${identifier.name} is not a same-file constant object`);
  }

  private parameter(parameter: Pattern, depth: number): ArgObject[] {
    const fn = parents.get(parameter) as FunctionNode;
    const name = functionName(fn);
    const calls = name ? callsOf(fn, name) : [];
    const named =
      parameter.type === 'AssignmentPattern'
        ? parameter.left
        : parameter.type === 'RestElement'
          ? parameter.argument
          : parameter;
    if (calls.length === 0)
      throw new Unreadable(
        `${this.text.slice(named.start, named.end)} is a parameter of a function never called in this file`,
      );
    const index = fn.params.indexOf(parameter);
    return capped(
      calls.flatMap((call) => {
        const argument = call.arguments[index];
        if (argument) return this.objects(argument, depth + 1);
        return parameter.type === 'AssignmentPattern' ? this.objects(parameter.right, depth + 1) : [{}];
      }),
    );
  }

  loopElements(name: string, bound: AnyNode): AnyNode[] | undefined {
    if (bound.type !== 'VariableDeclarator') return undefined;
    const declaration = parents.get(bound);
    if (declaration?.type !== 'VariableDeclaration') return undefined;
    const loop = parents.get(declaration);
    if (loop?.type !== 'ForOfStatement') return undefined;
    let iterated: AnyNode | undefined = loop.right;
    if (isIdentifier(iterated)) {
      const declared = binding(iterated);
      iterated = declared && isExpression(declared) ? declared : undefined;
    }
    if (iterated?.type !== 'ArrayExpression') return undefined;
    const items = iterated.elements.map((item) => {
      if (item === null) throw new Unreadable(`${name} comes from a loop over an array with a hole`);
      return item;
    });
    if (isIdentifier(bound.id)) return items;
    let property: string | undefined;
    if (bound.id.type === 'ObjectPattern') {
      for (const item of bound.id.properties) {
        if (item.type === 'RestElement') {
          if (boundName(item)?.name === name) property = name;
        } else if (boundName(item.value)?.name === name) {
          property = !item.computed && !item.shorthand && isIdentifier(item.key) ? item.key.name : name;
        }
        if (property !== undefined) break;
      }
    } else if (bound.id.type === 'ArrayPattern') {
      if (bound.id.elements.some((element) => boundName(element)?.name === name)) property = name;
    }
    if (property === undefined) return undefined;
    return items.map((item) => {
      if (item.type !== 'ObjectExpression') throw new Unreadable(`${name} comes from a loop over non-objects`);
      const found = item.properties.find(
        (candidate) =>
          candidate.type === 'Property' &&
          !candidate.computed &&
          isIdentifier(candidate.key) &&
          candidate.key.name === property,
      );
      if (found?.type === 'Property' && found.kind === 'init' && !found.method) return found.value;
      throw new Unreadable(`${name} is missing from a loop element`);
    });
  }

  private objectLiteral(expression: ObjectExpression, depth: number): ArgObject[] {
    let variants: ArgObject[] = [{}];
    for (const property of expression.properties) {
      if (property.type === 'SpreadElement') {
        const spread = this.objects(property.argument, depth + 1);
        variants = capped(variants.flatMap((left) => spread.map((right) => ({ ...left, ...right }))));
      } else if (property.shorthand && readableProperty(property)) {
        variants = variants.map((variant) => ({ ...variant, [propertyName(property.key)]: hole(property.value) }));
      } else if (readableProperty(property)) {
        const value = this.value(property.value, depth + 1);
        variants = variants.map((variant) => ({ ...variant, [propertyName(property.key)]: value }));
      } else throw new Unreadable('a computed or method property');
    }
    return variants;
  }

  value(expression: AnyNode, depth = 0): Value {
    if (expression.type === 'ParenthesizedExpression') return this.value(expression.expression, depth);
    if (expression.type === 'Literal' && expression.regex === undefined && expression.bigint === undefined) {
      return expression.value;
    }
    const text = stringText(expression);
    if (text !== undefined) return text;
    if (expression.type === 'UnaryExpression' && expression.operator === '-') {
      const operand = this.value(expression.argument, depth);
      return typeof operand === 'number' ? -operand : hole(expression);
    }
    if (
      expression.type === 'ArrayExpression' &&
      !expression.elements.some((element) => element?.type === 'SpreadElement')
    ) {
      return expression.elements.map((element) =>
        element === null ? hole(expression) : this.value(element, depth + 1),
      );
    }
    if (expression.type === 'ObjectExpression') {
      if (!expression.properties.every(readableProperty)) return hole(expression);
      const [only, ...more] = this.objectLiteral(expression, depth);
      return more.length === 0 ? only : hole(expression);
    }
    return hole(expression);
  }

  toolNames(expression: AnyNode): string[] | undefined {
    const text = stringText(expression);
    if (text !== undefined) return [text];
    if (isIdentifier(expression)) {
      const bound = binding(expression);
      const elements = bound && this.loopElements(expression.name, bound);
      const names = elements?.map(stringText);
      if (!names || names.some((name) => name === undefined)) return undefined;
      return names as string[];
    }
    if (expression.type === 'TemplateLiteral' && expression.expressions.length === 1) {
      const [head, tail] = expression.quasis;
      const inner = this.toolNames(expression.expressions[0]);
      return inner?.map((part) => `${head.value.cooked}${part}${tail.value.cooked}`);
    }
    return undefined;
  }
}

function callerName(call: CallExpression): string | undefined {
  const callee = call.callee;
  if (isIdentifier(callee)) return callee.name;
  if (callee.type === 'MemberExpression' && !callee.computed) {
    if (callee.property.type === 'Identifier' || callee.property.type === 'PrivateIdentifier')
      return callee.property.name;
  }
  return undefined;
}

function isPassThrough(expression: AnyNode): boolean {
  if (!isIdentifier(expression)) return false;
  const bound = binding(expression);
  return bound !== undefined && isParameter(bound);
}

export function scanSource(file: string, text: string): Scan {
  const source = parse(text, {
    ecmaVersion: 'latest',
    sourceType: 'module',
    locations: true,
    preserveParens: true,
    allowHashBang: true,
    allowReturnOutsideFunction: true,
  });
  linkParents(source);
  const reader = new Reader(text);
  const scan: Scan = { calls: [], unread: [], unknownTools: [], otherCallers: [] };
  const where = (node: AnyNode) => `${file}:${node.loc!.start.line}`;

  const add = (call: AnyNode, tools: string[], variants: () => ArgObject[], label: string) => {
    const unknown = tools.filter((tool) => !CHECKED_CONTRACTS.has(tool));
    for (const tool of unknown) scan.unknownTools.push(`${where(call)} ${tool}`);
    if (unknown.length > 0) return;
    try {
      const read = variants();
      for (const tool of tools) for (const args of read) scan.calls.push({ where: where(call), tool, args });
    } catch (error) {
      if (!(error instanceof Unreadable)) throw error;
      scan.unread.push({ where: where(call), file, tool: label, reason: error.message });
    }
  };

  const visit = (node: AnyNode): void => {
    if (node.type === 'CallExpression') {
      const name = callerName(node);
      const [first, second] = node.arguments;
      if (name === 'rpc' && first && stringText(first) === 'tools/call') {
        const passed =
          second?.type === 'ObjectExpression' &&
          second.properties.some(
            (property) =>
              property.type === 'Property' &&
              !property.computed &&
              isIdentifier(property.key) &&
              property.key.name === 'name' &&
              readableProperty(property) &&
              isPassThrough(property.value),
          );
        if (!passed) {
          try {
            for (const request of second ? reader.objects(second) : [{}]) {
              const tool = request.name;
              if (typeof tool !== 'string') throw new Unreadable('a tools/call request without a literal name');
              add(node, [tool], () => [(request.arguments ?? {}) as ArgObject], '<rpc>');
            }
          } catch (error) {
            if (!(error instanceof Unreadable)) throw error;
            scan.unread.push({ where: where(node), file, tool: '<rpc>', reason: error.message });
          }
        }
      } else if (
        !(name && CALLERS.has(name)) &&
        node.arguments.some((argument) => CHECKED_CONTRACTS.has(stringText(argument) ?? ''))
      ) {
        scan.otherCallers.push(name ?? '<anonymous>');
      } else if (name && CALLERS.has(name) && first && !isPassThrough(first)) {
        const tools = reader.toolNames(first);
        if (!tools) scan.unread.push({ where: where(node), file, tool: '<computed>', reason: 'computed tool name' });
        else add(node, tools, () => (second ? reader.objects(second) : [{}]), tools.join('|'));
      }
    }
    for (const child of childrenOf(node)) visit(child);
  };
  visit(source);
  return scan;
}

function sample(schema: Schema | undefined): unknown {
  if (!schema) return null;
  if (schema.const !== undefined) return schema.const;
  if (schema.enum) return schema.enum[0];
  const branch = schema.anyOf?.[0] ?? schema.oneOf?.[0];
  const type = Array.isArray(schema.type)
    ? schema.type[0]
    : (schema.type ?? (schema.properties ? 'object' : undefined));
  if (branch && type === undefined) return sample(branch);
  if (type === 'integer' || type === 'number') {
    const low = schema.minimum ?? schema.exclusiveMinimum;
    const high = schema.maximum ?? schema.exclusiveMaximum;
    if (low !== undefined && high !== undefined)
      return type === 'integer' ? Math.ceil((low + high) / 2) : (low + high) / 2;
    return low !== undefined ? low + 1 : high !== undefined ? high - 1 : 1;
  }
  if (type === 'string') return 'x';
  if (type === 'boolean') return true;
  if (type === 'array') return Array.from({ length: Math.max(schema.minItems ?? 1, 1) }, () => sample(schema.items));
  if (type === 'object') {
    const names = Object.keys(schema.properties ?? {});
    const wanted = new Set([
      ...(schema.required ?? []),
      ...(branch?.required ?? []),
      ...names.slice(0, schema.minProperties ?? 0),
    ]);
    const sampled: Record<string, unknown> = Object.fromEntries(
      [...wanted].map((name) => [name, sample(schema.properties?.[name])]),
    );
    for (let index = 0; Object.keys(sampled).length < (schema.minProperties ?? 0); index++)
      sampled[`key${index}`] = 'x';
    return sampled;
  }
  return null;
}

const isPhotoId = (schema: Schema | undefined) => schema?.pattern === PHOTO_ID_PATTERN;
const scalarExpression = (expression: AnyNode): boolean =>
  expression.type === 'Identifier' ||
  expression.type === 'MemberExpression' ||
  expression.type === 'CallExpression' ||
  (expression.type === 'ChainExpression' && scalarExpression(expression.expression)) ||
  (expression.type === 'TemplateLiteral' && expression.expressions.length > 0);

interface Completed {
  args: unknown;
  holes: number;
  problems: string[];
}

function complete(value: Value, schema: Schema | undefined, key: string, out: Completed): unknown {
  if (isHole(value)) {
    const expression = value[HOLE];
    out.holes += 1;
    if (key === 'photo_ids' && schema?.maxItems === 1) {
      out.problems.push(`photo_ids of a single-photo tool is an expression, not an array literal`);
      return [STAND_IN_ID];
    }
    if (key === 'photo_ids' || isPhotoId(schema)) {
      if (!scalarExpression(expression)) out.problems.push(`${key} is an expression the gate cannot read`);
      return key === 'photo_ids' ? [STAND_IN_ID] : STAND_IN_ID;
    }
    return sample(schema);
  }
  if (Array.isArray(value)) {
    return value.map((item) =>
      isHole(item) && isPhotoId(schema?.items)
        ? ((out.holes += 1), STAND_IN_ID)
        : complete(item, schema?.items, key, out),
    );
  }
  if (value === null || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, Value>).map(([name, item]) => [
      name,
      complete(item, schema?.properties?.[name], name, out),
    ]),
  );
}

export function verdictOf({ tool, args }: KitCall): { problem: string | null; fully: boolean } {
  const checked = CHECKED_CONTRACTS.get(tool)!;
  const out: Completed = { args: undefined, holes: 0, problems: [] };
  const completed = complete(args, checked.contract.inputSchema as Schema, '', out) as ToolArgs;
  if (out.problems.length > 0)
    return { problem: `Invalid arguments for ${tool}: ${out.problems.join('; ')}`, fully: false };
  if (out.holes === 0) return { problem: validateToolArgs(checked, completed), fully: true };
  return { problem: checked.validate(completed) ? null : validateToolArgs(checked, completed), fully: false };
}

function kitFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) return entry.name === 'unit' || entry.name === 'fixtures' ? [] : kitFiles(full);
    return entry.name.endsWith('.mjs') ? [full] : [];
  });
}

function scanKit(): Scan {
  const scans = kitFiles(KIT).map((file) => scanSource(path.relative(KIT, file), readFileSync(file, 'utf8')));
  return {
    calls: scans.flatMap((scan) => scan.calls),
    unread: scans.flatMap((scan) => scan.unread),
    unknownTools: scans.flatMap((scan) => scan.unknownTools),
    otherCallers: scans.flatMap((scan) => scan.otherCallers),
  };
}

const MEANT_TO_BE_REFUSED: [string, unknown][] = [
  ['set_rating_and_flag', { photo_ids: ['1'], rating: 9 }],
  ['create_collection', {}],
];

const NOT_READ: Omit<UnreadSite, 'where'>[] = [
  { file: 'mcp-runner.mjs', tool: '<computed>', reason: 'computed tool name' },
  {
    file: 'mcp-runner.mjs',
    tool: 'get_develop_preset',
    reason: 'exactPresetSelector(…) does not return an object literal',
  },
  {
    file: 'mcp-runner.mjs',
    tool: 'apply_develop_preset',
    reason: 'exactPresetSelector(…) does not return an object literal',
  },
];

const MEANT_UNKNOWN = ['does_not_exist'];

const NOT_CALLERS = ['includes', 'run', 'startsWith'];

function meantToBeRefused({ tool, args }: KitCall): boolean {
  return MEANT_TO_BE_REFUSED.some(
    ([name, refused]) =>
      name === tool &&
      JSON.stringify(refused) ===
        JSON.stringify(args, (_key, value: unknown) => (isHole(value) ? '<expression>' : value)),
  );
}

function refusedIn(file: string, text: string): string[] {
  const scan = scanSource(file, text);
  return [
    ...scan.calls.flatMap((call) => verdictOf(call).problem ?? []),
    ...scan.unread.map((site) => `${site.tool}: ${site.reason}`),
    ...scan.unknownTools,
    ...scan.otherCallers.filter((name) => !NOT_CALLERS.includes(name)).map((name) => `a tool name passed to ${name}`),
  ];
}

describe('the offline gate', () => {
  it.each([
    [
      'a constant argument object with an old name, sent whole and spread',
      'const args = { source_id: 1, photo_ids: [2], settings: ["Exposure2012"] };\nawait tool("copy_develop_settings", { ...args, dry_run: true });\nawait tool("copy_develop_settings", args);',
      2,
    ],
    ['a scalar photo_ids on a single-photo tool', 'await session.tool("get_crop", { photo_ids: photoId });', 1],
    [
      'a spread base carrying photo_id',
      'const base = { photo_id: 1 };\nawait session.tool("set_crop", { ...base, aspect: { width: 3, height: 2 } });',
      1,
    ],
    ['a computed tool name', 'await session.tool(name, { photo_ids: [1] });', 1],
    [
      'an argument variable with an old name',
      'const args = { photo_id: 1 };\nawait session.tool("get_crop", args);',
      1,
    ],
    ['an unknown tool name', 'await session.toolOrThrow("get_crops", { photo_ids: [1] });', 1],
    ['a tool name passed to a new wrapper', 'await invoke("get_crop", { photo_id: 1 });', 1],
    ['an unresolved spread', 'await data("set_crop", { photo_ids: [1], ...geometry() });', 1],
    [
      'an old name inside a tools/call request',
      'await session.rpc("tools/call", { name: "list_masks", arguments: { photo_id: 1 } });',
      1,
    ],
    [
      'an arrow helper returning an old name',
      'const linear = (y) => ({ photo_id: 1, shape: "linear", start: { x: 0.5, y } });\nawait tool("create_gradient_mask", linear(0.2));',
      1,
    ],
  ])('refuses %s', (_label, text, count) => {
    expect(refusedIn('probe.mjs', text)).toHaveLength(count);
  });

  it('passes the same calls with the current names', () => {
    const text = [
      'const args = { source_photo_id: 1, photo_ids: [2], settings: ["Exposure2012"] };',
      'await tool("copy_develop_settings", { ...args, dry_run: true });',
      'await session.tool("get_crop", { photo_ids: [photoId] });',
      'const linear = (y) => ({ photo_ids: [1], shape: "linear", start: { x: 0.5, y }, end: { x: 0.5, y: 0.9 } });',
      'await tool("create_gradient_mask", linear(0.2));',
      'await session.rpc("tools/call", { name: "list_masks", arguments: { photo_ids: [1] } });',
      'const call = (name, args) => session.toolOrThrow(name, args);',
      'await tool("create_develop_preset", { photo_ids: [1], preset_name: "x", settings: [key] });',
      'await tool("set_develop_settings", { photo_ids: [1], settings: { [key]: 1 } });',
    ].join('\n');
    expect(refusedIn('probe.mjs', text)).toEqual([]);
  });
});

describe('live kit calls', () => {
  const scan = scanKit();
  const verdicts = scan.calls.map((call) => ({ call, ...verdictOf(call) }));
  const fully = verdicts.filter((verdict) => verdict.fully).length;

  it(`are read at ${scan.calls.length} sites: ${fully} fully validated, ${scan.calls.length - fully} schema-checked around expressions`, () => {
    expect(scan.calls.length).toBeGreaterThan(300);
  });

  it('name only listed tools, apart from the call meant to name none', () => {
    expect(scan.unknownTools.map((site) => site.split(' ')[1])).toEqual(MEANT_UNKNOWN);
  });

  it('pass the tool contracts offline', () => {
    const refused = verdicts.flatMap(({ call, problem }) =>
      problem && !meantToBeRefused(call) ? [`${call.where} ${problem}`] : [],
    );
    expect(refused).toEqual([]);
  });

  it('keep the calls meant to be refused refused', () => {
    const meant = verdicts.filter(({ call }) => meantToBeRefused(call));
    expect([...new Set(meant.map(({ call }) => call.tool))].sort()).toEqual(
      MEANT_TO_BE_REFUSED.map(([name]) => name).sort(),
    );
    for (const { call, problem } of meant) expect([call.where, problem]).toEqual([call.where, expect.any(String)]);
  });

  it('pass tool names only to the kit wrappers, apart from labels and string checks', () => {
    expect([...new Set(scan.otherCallers)].sort()).toEqual(NOT_CALLERS);
  });

  it('leave unread only the listed sites', () => {
    expect(scan.unread.map(({ file, tool, reason }) => ({ file, tool, reason }))).toEqual(NOT_READ);
  });
});
