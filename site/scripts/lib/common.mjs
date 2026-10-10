// Shared helpers for the plugins-site prebuild scripts. Plain Node ESM, no dependencies.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const SITE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const REPO_DIR = path.resolve(SITE_DIR, '..');
export const DOCS_DIR = path.join(SITE_DIR, 'src', 'content', 'docs');
export const DATA_DIR = path.join(SITE_DIR, 'src', 'data');
export const PUBLIC_DIR = path.join(SITE_DIR, 'public');

export const BASE = '/melange-plugins';
export const REPO_URL = 'https://github.com/JaminB/melange-plugins';
export const BRANCH = 'main';
export const MELANGE_DOCS_URL = 'https://jaminb.github.io/melange/';

/** True when the module at `metaUrl` is the script node was started with. */
export function isMain(metaUrl) {
	return Boolean(process.argv[1]) && metaUrl === pathToFileURL(path.resolve(process.argv[1])).href;
}

// ---------------------------------------------------------------- diagnostics

export class HardError extends Error {}

/** Collects warnings for one script so it can print a single summary line. */
export class Report {
	constructor(name) {
		this.name = name;
		this.warnings = [];
	}
	warn(msg) {
		this.warnings.push(msg);
		console.warn(`[${this.name}] WARN ${msg}`);
	}
	summary(text) {
		const w = this.warnings.length ? ` (${this.warnings.length} warning${this.warnings.length === 1 ? '' : 's'})` : '';
		console.log(`[${this.name}] ${text}${w}`);
	}
}

/** Runs a script's main() standalone: prints the error and exits non-zero on failure. */
export async function runStandalone(main) {
	try {
		await main({ write: true });
	} catch (err) {
		console.error(err instanceof HardError ? `ERROR ${err.message}` : err);
		process.exit(1);
	}
}

// ---------------------------------------------------------------- files

export function readJson(file) {
	let text;
	try {
		text = fs.readFileSync(file, 'utf8');
	} catch {
		throw new HardError(`missing ${rel(file)}`);
	}
	try {
		return JSON.parse(text.replace(/^﻿/, ''));
	} catch (err) {
		throw new HardError(`${rel(file)} is not valid JSON: ${err.message}`);
	}
}

export function readText(file) {
	return fs.readFileSync(file, 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n');
}

export function exists(file) {
	return fs.existsSync(file);
}

/** Deletes and recreates a generated output directory. */
export function cleanDir(dir) {
	fs.rmSync(dir, { recursive: true, force: true });
	fs.mkdirSync(dir, { recursive: true });
}

export function writeFile(file, content) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, content);
}

export function copyFile(from, to) {
	fs.mkdirSync(path.dirname(to), { recursive: true });
	fs.copyFileSync(from, to);
}

/** Repo-relative path with forward slashes, for messages and GitHub URLs. */
export function rel(file) {
	return path.relative(REPO_DIR, file).split(path.sep).join('/');
}

export function blobUrl(repoRel) {
	return `${REPO_URL}/blob/${BRANCH}/${repoRel}`;
}
export function treeUrl(repoRel) {
	return `${REPO_URL}/tree/${BRANCH}/${repoRel}`;
}
export function editUrl(repoRel) {
	return `${REPO_URL}/edit/${BRANCH}/${repoRel}`;
}

/** Repo files that have a page on this site, as repo path -> site URL (used when rewriting relative links). */
export function sitePageMap(pluginIds) {
	const map = {
		'README.md': `${BASE}/about/`,
		'CONTRIBUTING.md': `${BASE}/publish/`,
		'schema/store-1.schema.json': `${BASE}/publish/store-json/`,
		'schema/index-1.schema.json': `${BASE}/publish/index-json/`,
		'schema/import-1.schema.json': `${BASE}/publish/import-json/`,
		policy: `${BASE}/publish/policy/`,
		plugins: `${BASE}/`,
	};
	for (const f of ['executables.json', 'extra-types.json', 'import-hosts.json', 'reserved-ids.txt', 'stock-names.txt']) {
		map[`policy/${f}`] = `${BASE}/publish/policy/`;
	}
	for (const id of pluginIds) {
		map[`plugins/${id}`] = `${BASE}/plugins/${id}/`;
		map[`plugins/${id}/README.md`] = `${BASE}/plugins/${id}/`;
		map[`plugins/${id}/CHANGELOG.md`] = `${BASE}/plugins/${id}/#versions`;
	}
	return map;
}

/** Date of the last commit touching a repo file (Date), or undefined (untracked, no git). */
export function gitDate(repoRel) {
	try {
		const out = execFileSync('git', ['log', '-1', '--format=%cs', '--', repoRel], {
			cwd: REPO_DIR,
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'ignore'],
		}).trim();
		return /^\d{4}-\d{2}-\d{2}$/.test(out) ? new Date(`${out}T00:00:00Z`) : undefined;
	} catch {
		return undefined;
	}
}

// ---------------------------------------------------------------- markdown

/** YAML frontmatter. Strings are JSON-quoted, which is valid YAML. */
export function frontmatter(data) {
	const lines = ['---'];
	const emit = (key, value, indent) => {
		const pad = '  '.repeat(indent);
		if (value === undefined) return;
		if (value instanceof Date) {
			lines.push(`${pad}${key}: ${value.toISOString().slice(0, 10)}`); // unquoted: YAML reads it as a date
		} else if (value && typeof value === 'object' && !Array.isArray(value)) {
			lines.push(`${pad}${key}:`);
			for (const [k, v] of Object.entries(value)) emit(k, v, indent + 1);
		} else {
			lines.push(`${pad}${key}: ${JSON.stringify(value)}`);
		}
	};
	for (const [k, v] of Object.entries(data)) emit(k, v, 0);
	lines.push('---', '');
	return lines.join('\n');
}

/** Removes the first H1 and returns { title, body }. */
export function stripH1(md) {
	const m = md.match(/^# +(.+?)\s*#*\s*$/m);
	if (!m) return { title: undefined, body: md };
	const body = (md.slice(0, m.index) + md.slice(m.index + m[0].length)).replace(/^\s*\n/, '');
	return { title: m[1].trim(), body };
}

/** Plain text of the first paragraph (no headings, lists, code), truncated at a word. */
export function firstParagraph(md, max = 160) {
	const blocks = md.split(/\n\s*\n/);
	for (const b of blocks) {
		const t = b.trim();
		if (!t || /^(#|```|~~~|[-*+] |\d+\. |\||>|<|:::)/.test(t)) continue;
		return truncate(plain(t), max);
	}
	return undefined;
}

export function plain(md) {
	return md
		.replace(/!\[[^\]]*\]\([^)]*\)/g, '')
		.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
		.replace(/[`*_]/g, '')
		.replace(/\s+/g, ' ')
		.trim();
}

export function truncate(text, max) {
	if (text.length <= max) return text;
	const cut = text.slice(0, max - 1);
	const sp = cut.lastIndexOf(' ');
	return `${(sp > max * 0.6 ? cut.slice(0, sp) : cut).replace(/[\s,;:.]+$/, '')}…`;
}

/** Shifts every ATX heading down by `by` levels (capped at 6), outside code fences. */
export function demoteHeadings(md, by) {
	return mapProse(md, (line) => line.replace(/^(#{1,6})(?= )/, (h) => '#'.repeat(Math.min(6, h.length + by))), true);
}

/**
 * Applies fn to markdown outside fenced code blocks. With perLine, fn gets each line; otherwise it gets each
 * prose chunk with inline code spans protected (replaced by placeholders and restored afterwards).
 */
export function mapProse(md, fn, perLine = false) {
	const lines = md.split('\n');
	const out = [];
	let fence = null;
	let chunk = [];
	const flush = () => {
		if (!chunk.length) return;
		out.push(perLine ? chunk.map(fn).join('\n') : protectInlineCode(chunk.join('\n'), fn));
		chunk = [];
	};
	for (const line of lines) {
		const f = line.match(/^\s*(`{3,}|~{3,})/);
		if (fence) {
			out.push(line);
			if (f && f[1][0] === fence[0] && f[1].length >= fence.length && line.trim() === f[1]) fence = null;
		} else if (f) {
			flush();
			fence = f[1];
			out.push(line);
		} else {
			chunk.push(line);
		}
	}
	flush();
	return out.join('\n');
}

function protectInlineCode(text, fn) {
	const spans = [];
	const masked = text.replace(/(`+)([\s\S]*?[^`])\1(?!`)/g, (m) => {
		spans.push(m);
		return `\u0000${spans.length - 1}\u0000`;
	});
	return fn(masked).replace(/\u0000(\d+)\u0000/g, (_, i) => spans[Number(i)]);
}

const HTML_TAGS = new Set(
	'a abbr b br code del details div em h1 h2 h3 h4 h5 h6 hr i img kbd li ol p picture pre s small source span strong sub summary sup table tbody td th thead tr u ul video'.split(' '),
);

/** Escapes `<` in prose that does not start a real HTML tag (e.g. "<id>"), so markdown doesn't eat it as HTML. */
export function escapeStrayAngles(md) {
	return mapProse(md, (t) =>
		t.replace(/<(\/?)([A-Za-z][\w-]*)?(?![\w-]*:)/g, (m, slash, name) => {
			if (name && HTML_TAGS.has(name.toLowerCase())) return m;
			if (!name && !slash) return m; // "<!--", "< 3" etc. are not tags anyway
			return `&lt;${slash}${name ?? ''}`;
		}),
	);
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|avif)$/i;

/**
 * Rewrites relative links and images in markdown that lives at repo-relative directory `fromDir`.
 * - images (or links to images) inside `assetRoot` are copied to public/<assetUrlDir>/... by `copyAsset`
 * - repo files with a page on this site (pageMap: repo path -> site path) link to that page
 * - other repo files link to GitHub; unknown targets are left as-is and reported.
 */
export function rewriteLinks(md, { fromDir, pageMap = {}, copyAsset, report }) {
	const resolveTarget = (raw, isImage) => {
		const m = raw.match(/^(<?)([^\s>]+?)(>?)(\s+["'(].*)?$/s);
		if (!m) return raw;
		const [, lt, target, gt, titlePart = ''] = m;
		if (/^([a-z][a-z0-9+.-]*:|#|\/\/)/i.test(target)) return raw;
		if (target.startsWith('/')) return raw;
		const [pathPart, hash = ''] = target.split(/(?=#)/);
		const repoRel = path.posix.normalize(path.posix.join(fromDir, decodeURI(pathPart)));
		const abs = path.join(REPO_DIR, ...repoRel.split('/'));
		let url;
		if (pageMap[repoRel] !== undefined) url = pageMap[repoRel] + hash;
		else if (!repoRel.startsWith('..') && fs.existsSync(abs)) {
			if ((isImage || IMAGE_EXT.test(repoRel)) && copyAsset) url = copyAsset(repoRel);
			if (!url) url = (fs.statSync(abs).isDirectory() ? treeUrl(repoRel) : blobUrl(repoRel)) + hash;
		} else {
			report?.warn(`unresolved link "${target}" in ${fromDir || '.'}/`);
			return raw;
		}
		return `${lt}${url}${gt}${titlePart}`;
	};
	return mapProse(md, (t) =>
		t
			.replace(/(!?)\[((?:[^\][]|\[[^\]]*\])*)\]\(([^)\s]+(?:\s+"[^"]*")?)\)/g, (m, bang, text, target) =>
				`${bang}[${text}](${resolveTarget(target.trim(), bang === '!')})`,
			)
			.replace(/^(\s{0,3}\[[^\]]+\]:\s+)(\S+)/gm, (m, lead, target) => lead + resolveTarget(target, false))
			.replace(/(<img\b[^>]*?\bsrc=")([^"]+)(")/gi, (m, a, src, b) => a + resolveTarget(src, true) + b),
	);
}

// ---------------------------------------------------------------- formatting

export function escapeHtml(s) {
	return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

/** 453051 -> "442 KB", 16316968 -> "15.6 MB" (binary units, as Windows Explorer shows them). */
export function formatSize(bytes) {
	if (typeof bytes !== 'number') return '';
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
	const mb = bytes / (1024 * 1024);
	return `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
}

/** ">=0.3.5" -> "0.3.5 or later"; ">=0.3.5 <0.7.0" -> "0.3.5 up to (not including) 0.7.0"; else as-is. */
export function describeRange(range) {
	const r = String(range ?? '').trim();
	let m = r.match(/^>=\s*(\S+)$/);
	if (m) return `${m[1]} or later`;
	m = r.match(/^>=\s*(\S+)\s+<\s*(\S+)$/);
	if (m) return `${m[1]} up to (not including) ${m[2]}`;
	return r || 'any version';
}

/** ">=0.3.5" -> "0.3.5" (the minimum Melange version), or null. */
export function minVersion(range) {
	const m = String(range ?? '').match(/>=\s*([0-9][^\s]*)/);
	return m ? m[1] : null;
}
