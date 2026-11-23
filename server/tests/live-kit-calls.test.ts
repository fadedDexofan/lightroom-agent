import { describe, it, expect } from '@jest/globals';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import ts from 'typescript';
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
  [HOLE]: ts.Expression;
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

const hole = (expression: ts.Expression): Hole => ({ [HOLE]: expression });
const isHole = (value: unknown): value is Hole => typeof value === 'object' && value !== null && HOLE in value;

function declaredIn(statements: readonly ts.Statement[], name: string): ts.Node | undefined {
  for (const statement of statements) {
    if (ts.isFunctionDeclaration(statement) && statement.name?.text === name) return statement;
    if (!ts.isVariableStatement(statement)) continue;
    for (const declaration of statement.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.name.text === name) {
        const constant = (statement.declarationList.flags & ts.NodeFlags.Const) !== 0;
        return constant && declaration.initializer ? declaration.initializer : declaration;
      }
      if (
        !ts.isIdentifier(declaration.name) &&
        declaration.name.elements.some(
          (element) => ts.isBindingElement(element) && ts.isIdentifier(element.name) && element.name.text === name,
        )
      ) {
        return declaration;
      }
    }
  }
  return undefined;
}

function patternHolds(pattern: ts.BindingName, name: string): boolean {
  if (ts.isIdentifier(pattern)) return pattern.text === name;
  return pattern.elements.some((element) => ts.isBindingElement(element) && patternHolds(element.name, name));
}

function binding(identifier: ts.Identifier): ts.Node | undefined {
  const name = identifier.text;
  for (let scope: ts.Node | undefined = identifier.parent; scope; scope = scope.parent) {
    if (ts.isBlock(scope) || ts.isSourceFile(scope) || ts.isCaseClause(scope) || ts.isDefaultClause(scope)) {
      const found = declaredIn(scope.statements, name);
      if (found) return found;
    }
    if (ts.isFunctionLike(scope)) {
      const parameter = scope.parameters.find((item) => ts.isIdentifier(item.name) && item.name.text === name);
      if (parameter) return parameter;
    }
    if (
      (ts.isForOfStatement(scope) || ts.isForInStatement(scope) || ts.isForStatement(scope)) &&
      scope.initializer &&
      ts.isVariableDeclarationList(scope.initializer)
    ) {
      const declared = scope.initializer.declarations.find((item) => patternHolds(item.name, name));
      if (declared) return declared;
    }
    if (
      ts.isCatchClause(scope) &&
      scope.variableDeclaration &&
      ts.isIdentifier(scope.variableDeclaration.name) &&
      scope.variableDeclaration.name.text === name
    ) {
      return scope.variableDeclaration;
    }
  }
  return undefined;
}

function returnedObject(node: ts.Node): ts.Expression | undefined {
  const body =
    ts.isArrowFunction(node) || ts.isFunctionExpression(node) || ts.isFunctionDeclaration(node) ? node.body : undefined;
  if (!body) return undefined;
  if (!ts.isBlock(body)) return body;
  const returns = body.statements.filter(ts.isReturnStatement);
  return body.statements.length === 1 && returns.length === 1 ? returns[0].expression : undefined;
}

function functionName(fn: ts.SignatureDeclaration): ts.Identifier | undefined {
  if (ts.isFunctionDeclaration(fn)) return fn.name;
  if ((ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)) && ts.isVariableDeclaration(fn.parent)) {
    return ts.isIdentifier(fn.parent.name) ? fn.parent.name : undefined;
  }
  return undefined;
}

function callsOf(fn: ts.SignatureDeclaration, name: ts.Identifier): ts.CallExpression[] {
  const calls: ts.CallExpression[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === name.text) {
      const bound = binding(node.expression);
      if (bound === fn) calls.push(node);
    }
    ts.forEachChild(node, visit);
  };
  visit(fn.getSourceFile());
  return calls;
}

const MAX_VARIANTS = 64;
type ArgObject = Record<string, Value>;

function capped<T>(variants: T[]): T[] {
  if (variants.length > MAX_VARIANTS) throw new Unreadable('more argument variants than the gate reads');
  return variants;
}

class Reader {
  objects(expression: ts.Expression, depth = 0): ArgObject[] {
    if (depth > 12) throw new Unreadable('nested too deep');
    if (ts.isParenthesizedExpression(expression)) return this.objects(expression.expression, depth + 1);
    if (ts.isObjectLiteralExpression(expression)) return this.objectLiteral(expression, depth);
    if (ts.isIdentifier(expression)) return this.bound(expression, depth);
    if (ts.isCallExpression(expression) && ts.isIdentifier(expression.expression)) {
      const bound = binding(expression.expression);
      const returned = bound && returnedObject(bound);
      if (returned) return this.objects(returned, depth + 1);
      throw new Unreadable(`${expression.expression.text}(…) does not return an object literal`);
    }
    if (ts.isConditionalExpression(expression)) {
      return capped([
        ...this.objects(expression.whenTrue, depth + 1),
        ...this.objects(expression.whenFalse, depth + 1),
      ]);
    }
    throw new Unreadable(`an argument object built by ${ts.SyntaxKind[expression.kind]}`);
  }

  private bound(identifier: ts.Identifier, depth: number): ArgObject[] {
    const bound = binding(identifier);
    if (bound && ts.isParameter(bound)) return this.parameter(bound, depth);
    if (bound && ts.isExpression(bound) && !ts.isArrowFunction(bound) && !ts.isFunctionExpression(bound)) {
      return this.objects(bound, depth + 1);
    }
    const elements = bound && this.loopElements(identifier.text, bound);
    if (elements) return capped(elements.flatMap((element) => this.objects(element, depth + 1)));
    throw new Unreadable(`${identifier.text} is not a same-file constant object`);
  }

  private parameter(parameter: ts.ParameterDeclaration, depth: number): ArgObject[] {
    const fn = parameter.parent;
    const name = functionName(fn);
    const calls = name ? callsOf(fn, name) : [];
    if (calls.length === 0)
      throw new Unreadable(`${parameter.name.getText()} is a parameter of a function never called in this file`);
    const index = fn.parameters.indexOf(parameter);
    return capped(
      calls.flatMap((call) => {
        const argument = call.arguments[index];
        if (argument) return this.objects(argument, depth + 1);
        return parameter.initializer ? this.objects(parameter.initializer, depth + 1) : [{}];
      }),
    );
  }

  loopElements(name: string, bound: ts.Node): ts.Expression[] | undefined {
    if (!ts.isVariableDeclaration(bound) || !ts.isVariableDeclarationList(bound.parent)) return undefined;
    const loop = bound.parent.parent;
    if (!ts.isForOfStatement(loop)) return undefined;
    let iterated: ts.Expression | undefined = loop.expression;
    if (ts.isIdentifier(iterated)) {
      const declared = binding(iterated);
      iterated = declared && ts.isExpression(declared) ? declared : undefined;
    }
    if (!iterated || !ts.isArrayLiteralExpression(iterated)) return undefined;
    if (ts.isIdentifier(bound.name)) return [...iterated.elements];
    const element = (bound.name.elements as readonly ts.ArrayBindingElement[])
      .filter(ts.isBindingElement)
      .find((item) => ts.isIdentifier(item.name) && item.name.text === name);
    if (!element) return undefined;
    const property = element.propertyName && ts.isIdentifier(element.propertyName) ? element.propertyName.text : name;
    return iterated.elements.map((item) => {
      if (!ts.isObjectLiteralExpression(item)) throw new Unreadable(`${name} comes from a loop over non-objects`);
      const found = item.properties.find(
        (candidate) => candidate.name && ts.isIdentifier(candidate.name) && candidate.name.text === property,
      );
      if (found && ts.isPropertyAssignment(found)) return found.initializer;
      if (found && ts.isShorthandPropertyAssignment(found)) return found.name;
      throw new Unreadable(`${name} is missing from a loop element`);
    });
  }

  private objectLiteral(expression: ts.ObjectLiteralExpression, depth: number): ArgObject[] {
    let variants: ArgObject[] = [{}];
    for (const property of expression.properties) {
      if (ts.isSpreadAssignment(property)) {
        const spread = this.objects(property.expression, depth + 1);
        variants = capped(variants.flatMap((left) => spread.map((right) => ({ ...left, ...right }))));
      } else if (ts.isShorthandPropertyAssignment(property)) {
        variants = variants.map((variant) => ({ ...variant, [property.name.text]: hole(property.name) }));
      } else if (ts.isPropertyAssignment(property) && !ts.isComputedPropertyName(property.name)) {
        const value = this.value(property.initializer, depth + 1);
        variants = variants.map((variant) => ({ ...variant, [(property.name as ts.Identifier).text]: value }));
      } else throw new Unreadable('a computed or method property');
    }
    return variants;
  }

  value(expression: ts.Expression, depth = 0): Value {
    if (ts.isParenthesizedExpression(expression)) return this.value(expression.expression, depth);
    if (ts.isNumericLiteral(expression)) return Number(expression.text);
    if (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) return expression.text;
    if (expression.kind === ts.SyntaxKind.TrueKeyword) return true;
    if (expression.kind === ts.SyntaxKind.FalseKeyword) return false;
    if (expression.kind === ts.SyntaxKind.NullKeyword) return null;
    if (ts.isPrefixUnaryExpression(expression) && expression.operator === ts.SyntaxKind.MinusToken) {
      const operand = this.value(expression.operand, depth);
      return typeof operand === 'number' ? -operand : hole(expression);
    }
    if (ts.isArrayLiteralExpression(expression) && !expression.elements.some(ts.isSpreadElement)) {
      return expression.elements.map((element) => this.value(element, depth + 1));
    }
    if (ts.isObjectLiteralExpression(expression)) {
      const readable = expression.properties.every(
        (property) =>
          ts.isSpreadAssignment(property) ||
          ts.isShorthandPropertyAssignment(property) ||
          (ts.isPropertyAssignment(property) && !ts.isComputedPropertyName(property.name)),
      );
      if (!readable) return hole(expression);
      const [only, ...more] = this.objectLiteral(expression, depth);
      return more.length === 0 ? only : hole(expression);
    }
    return hole(expression);
  }

  toolNames(expression: ts.Expression): string[] | undefined {
    if (ts.isStringLiteralLike(expression)) return [expression.text];
    if (ts.isIdentifier(expression)) {
      const bound = binding(expression);
      const elements = bound && this.loopElements(expression.text, bound);
      if (!elements || !elements.every(ts.isStringLiteralLike)) return undefined;
      return elements.map((element) => (element as ts.StringLiteralLike).text);
    }
    if (ts.isTemplateExpression(expression) && expression.templateSpans.length === 1) {
      const [span] = expression.templateSpans;
      const inner = this.toolNames(span.expression);
      return inner?.map((part) => `${expression.head.text}${part}${span.literal.text}`);
    }
    return undefined;
  }
}

function callerName(call: ts.CallExpression): string | undefined {
  const callee = call.expression;
  if (ts.isIdentifier(callee)) return callee.text;
  if (ts.isPropertyAccessExpression(callee)) return callee.name.text;
  return undefined;
}

function isPassThrough(expression: ts.Expression): boolean {
  if (!ts.isIdentifier(expression)) return false;
  const bound = binding(expression);
  return bound !== undefined && ts.isParameter(bound);
}

export function scanSource(file: string, text: string): Scan {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const reader = new Reader();
  const scan: Scan = { calls: [], unread: [], unknownTools: [], otherCallers: [] };
  const where = (node: ts.Node) => `${file}:${source.getLineAndCharacterOfPosition(node.getStart()).line + 1}`;

  const add = (call: ts.Node, tools: string[], variants: () => ArgObject[], label: string) => {
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

  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node)) {
      const name = callerName(node);
      const [first, second] = node.arguments;
      if (name === 'rpc' && first && ts.isStringLiteralLike(first) && first.text === 'tools/call') {
        const passed =
          second &&
          ts.isObjectLiteralExpression(second) &&
          second.properties.some(
            (property) =>
              property.name?.getText() === 'name' &&
              (ts.isShorthandPropertyAssignment(property)
                ? isPassThrough(property.name)
                : ts.isPropertyAssignment(property) && isPassThrough(property.initializer)),
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
        node.arguments.some((argument) => ts.isStringLiteralLike(argument) && CHECKED_CONTRACTS.has(argument.text))
      ) {
        scan.otherCallers.push(name ?? '<anonymous>');
      } else if (name && CALLERS.has(name) && first && !isPassThrough(first)) {
        const tools = reader.toolNames(first);
        if (!tools) scan.unread.push({ where: where(node), file, tool: '<computed>', reason: 'computed tool name' });
        else add(node, tools, () => (second ? reader.objects(second) : [{}]), tools.join('|'));
      }
    }
    ts.forEachChild(node, visit);
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
const scalarExpression = (expression: ts.Expression) =>
  ts.isIdentifier(expression) ||
  ts.isPropertyAccessExpression(expression) ||
  ts.isElementAccessExpression(expression) ||
  ts.isCallExpression(expression) ||
  ts.isTemplateExpression(expression);

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
