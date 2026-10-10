// Generic JSON Schema (draft-07 subset) -> Markdown reference renderer.
//
// KEEP IN SYNC: this module is copied verbatim between the two GitHub Pages sites,
//   melange          site/scripts/lib/schema-md.mjs
//   melange-plugins  site/scripts/lib/schema-md.mjs
// (the owner chose copying over a shared package). Change both copies together.
// It has no imports, so it can be copied without edits.
//
// Output: one section per object in the schema (the root first, then nested objects and arrays of objects, depth
// first), each a table: Property | Type | Required | Default | Description. Enums, consts, patterns, formats and
// length / range / item limits are listed in the Description column; patterns are shown as code.

/**
 * @param {object} schema  a parsed JSON Schema
 * @param {object} [opts]
 * @param {number} [opts.headingLevel=2]  heading level of each object section
 * @param {string} [opts.rootLabel='Top level']  heading text of the root object's section
 * @returns {{title: string|undefined, description: string|undefined, markdown: string}}
 */
export function schemaToMarkdown(schema, opts = {}) {
	const level = opts.headingLevel ?? 2;
	const rootLabel = opts.rootLabel ?? 'Top level';
	const sections = [];
	const slugs = new Map();

	const resolve = (s) => deref(schema, s);

	// Pass 1: collect every object section with its path, so rows can link to sections that come later.
	const collect = (node, pathLabel, heading) => {
		node = resolve(node);
		const props = node?.properties;
		if (!props || typeof props !== 'object') return;
		const section = { node, pathLabel, heading, slug: slugify(heading, slugs), children: new Map() };
		sections.push(section);
		for (const [name, raw] of Object.entries(props)) {
			const prop = resolve(raw);
			const childPath = pathLabel ? `${pathLabel}.${name}` : name;
			const target = objectTarget(prop, resolve);
			if (target) {
				const label = target.array ? `${childPath}[]` : childPath;
				const before = sections.length;
				collect(target.node, label, label);
				if (sections.length > before) section.children.set(name, sections[before]);
			}
		}
	};
	collect(schema, '', rootLabel);

	const h = '#'.repeat(level);
	const out = [];
	for (const s of sections) {
		out.push(`${h} ${s.heading === rootLabel ? rootLabel : `\`${s.heading}\``}`, '');
		if (s.node.description && s !== sections[0]) out.push(oneLine(s.node.description), '');
		const required = new Set(Array.isArray(s.node.required) ? s.node.required : []);
		out.push('| Property | Type | Required | Default | Description |', '| --- | --- | --- | --- | --- |');
		for (const [name, raw] of Object.entries(s.node.properties)) {
			const prop = resolve(raw);
			const child = s.children.get(name);
			const desc = describe(prop, resolve);
			if (child) desc.push(`See [\`${child.heading}\`](#${child.slug}).`);
			out.push(
				`| ${cell(code(name))} | ${cell(typeOf(prop, resolve))} | ${required.has(name) ? 'yes' : ''} | ${
					prop.default !== undefined ? cell(code(JSON.stringify(prop.default))) : ''
				} | ${cell(desc.join(' '))} |`,
			);
		}
		out.push('');
		const extra = s.node.additionalProperties;
		if (extra === false) out.push('No other properties are allowed.', '');
		else if (extra && typeof extra === 'object') out.push(`Other properties are allowed, each of type ${typeOf(resolve(extra), resolve)}.`, '');
	}

	return {
		title: schema.title,
		description: schema.description,
		markdown: out.join('\n').trimEnd() + '\n',
	};
}

function deref(root, node) {
	let n = node;
	for (let i = 0; i < 16 && n && typeof n.$ref === 'string' && n.$ref.startsWith('#/'); i++) {
		n = n.$ref
			.slice(2)
			.split('/')
			.map((p) => p.replace(/~1/g, '/').replace(/~0/g, '~'))
			.reduce((acc, key) => (acc == null ? acc : acc[key]), root);
	}
	return n ?? {};
}

/** The object schema a property leads to (itself, or its array items), or null. */
function objectTarget(prop, resolve) {
	if (prop.properties) return { node: prop, array: false };
	if (prop.items && !Array.isArray(prop.items)) {
		const items = resolve(prop.items);
		if (items.properties) return { node: items, array: true };
	}
	return null;
}

function typeOf(prop, resolve) {
	const variants = prop.oneOf ?? prop.anyOf;
	if (Array.isArray(variants)) return [...new Set(variants.map((v) => typeOf(resolve(v), resolve)))].join(' \\| ');
	let t = prop.type;
	if (t === undefined && prop.const !== undefined) t = jsonType(prop.const);
	if (t === undefined && Array.isArray(prop.enum)) t = [...new Set(prop.enum.map(jsonType))];
	if (t === undefined) return prop.properties ? 'object' : 'any';
	const types = Array.isArray(t) ? t : [t];
	return types
		.map((one) => {
			if (one === 'array' && prop.items && !Array.isArray(prop.items)) {
				const inner = typeOf(resolve(prop.items), resolve);
				return inner.includes('|') ? `(${inner})[]` : `${inner}[]`;
			}
			return one;
		})
		.join(' \\| ');
}

function jsonType(v) {
	if (v === null) return 'null';
	if (Array.isArray(v)) return 'array';
	if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
	return typeof v;
}

function describe(prop, resolve) {
	const parts = [];
	if (prop.description) parts.push(oneLine(prop.description));
	if (prop.const !== undefined) parts.push(`Must be ${code(JSON.stringify(prop.const))}.`);
	if (Array.isArray(prop.enum)) parts.push(`One of: ${prop.enum.map((v) => code(typeof v === 'string' ? v : JSON.stringify(v))).join(', ')}.`);
	parts.push(...limits(prop));
	const items = prop.items && !Array.isArray(prop.items) ? resolve(prop.items) : null;
	if (items && !items.properties) {
		const sub = [];
		if (items.const !== undefined) sub.push(`must be ${code(JSON.stringify(items.const))}`);
		if (Array.isArray(items.enum)) sub.push(`one of: ${items.enum.map((v) => code(typeof v === 'string' ? v : JSON.stringify(v))).join(', ')}`);
		sub.push(...limits(items).map((l) => l.replace(/\.$/, '').replace(/^./, (c) => c.toLowerCase())));
		if (sub.length) parts.push(`Each item: ${sub.join('; ')}.`);
	}
	const variants = prop.oneOf ?? prop.anyOf;
	if (Array.isArray(variants)) {
		const vs = variants
			.map((v) => resolve(v))
			.map((v) => {
				const l = [...limits(v)];
				if (v.items && !Array.isArray(v.items)) l.push(...limits(resolve(v.items)).map((x) => `items: ${x}`));
				return l.length ? `${typeOf(v, resolve)} (${l.join(' ').replace(/\.$/, '')})` : null;
			})
			.filter(Boolean);
		if (vs.length) parts.push(`Either ${vs.join(' or ')}.`);
	}
	return parts;
}

function limits(p) {
	const out = [];
	if (p.pattern) out.push(`Pattern: ${code(p.pattern)}.`);
	if (p.format) out.push(`Format: ${p.format}.`);
	const range = (min, max, unit) => {
		const u = (n) => (n === 1 ? unit.replace(/s$/, '') : unit);
		if (min !== undefined && max !== undefined) return min === max ? `Exactly ${min} ${u(min)}.` : `${min} to ${max} ${u(max)}.`;
		if (min !== undefined) return `At least ${min} ${u(min)}.`;
		if (max !== undefined) return `At most ${max} ${u(max)}.`;
		return null;
	};
	const len = range(p.minLength, p.maxLength, 'characters');
	if (len) out.push(len);
	const items = range(p.minItems, p.maxItems, 'items');
	if (items) out.push(items);
	if (p.uniqueItems) out.push('Items must be unique.');
	const num = (() => {
		const lo = p.minimum ?? (p.exclusiveMinimum !== undefined ? `> ${p.exclusiveMinimum}` : undefined);
		const hi = p.maximum ?? (p.exclusiveMaximum !== undefined ? `< ${p.exclusiveMaximum}` : undefined);
		if (lo !== undefined && hi !== undefined) return `From ${lo} to ${hi}.`;
		if (lo !== undefined) return `Minimum ${lo}.`;
		if (hi !== undefined) return `Maximum ${hi}.`;
		return null;
	})();
	if (num) out.push(num);
	return out;
}

/** Inline code that survives backticks in the content. */
function code(s) {
	const str = String(s);
	const runs = str.match(/`+/g) ?? [];
	const fence = '`'.repeat(Math.max(0, ...runs.map((r) => r.length)) + 1);
	const pad = str.startsWith('`') || str.endsWith('`') ? ' ' : '';
	return `${fence}${pad}${str}${pad}${fence}`;
}

/** A table cell: one line, pipes escaped (GFM requires that even inside code spans). */
function cell(s) {
	return String(s).replace(/\r?\n/g, ' ').replace(/(?<!\\)\|/g, '\\|');
}

function oneLine(s) {
	return String(s).replace(/\s+/g, ' ').trim();
}

/** github-slugger compatible (ASCII subset) with duplicate counting, as rehype-slug does. */
function slugify(text, seen) {
	const base = text
		.toLowerCase()
		.replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, '')
		.replace(/ /g, '-');
	let slug = base;
	while (seen.has(slug)) {
		seen.set(base, seen.get(base) + 1);
		slug = `${base}-${seen.get(base)}`;
	}
	seen.set(slug, 0);
	return slug;
}
