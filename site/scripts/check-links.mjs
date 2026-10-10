// Internal link check over the built site (run after `npm run build`; CI runs it as `npm run check:links`).
// Every href/src/srcset URL in dist/**/*.html that starts with the site base (/melange-plugins/) must resolve to a file
// in dist/: "/melange-plugins/x/" -> dist/x/index.html, "/melange-plugins/a.css" -> dist/a.css. Fragments are checked
// against the target page's ids when the target is an HTML page (pass --no-anchors to skip that). Exits 1 and lists
// every failure.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = '/melange-plugins/';
const DIST = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const checkAnchors = !process.argv.includes('--no-anchors');

if (!fs.existsSync(DIST)) {
	console.error('[check-links] dist/ not found; run `npm run build` first');
	process.exit(1);
}

function walk(dir) {
	return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
		const p = path.join(dir, e.name);
		return e.isDirectory() ? walk(p) : [p];
	});
}

const decode = (s) => s.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>');

/** URL path under the base -> file in dist/, or null. */
function resolve(urlPath) {
	let rel;
	try {
		rel = decodeURIComponent(urlPath.slice(BASE.length));
	} catch {
		return null;
	}
	const candidates = rel === '' || rel.endsWith('/') ? [path.join(rel, 'index.html')] : [rel, path.join(rel, 'index.html')];
	for (const c of candidates) {
		const f = path.join(DIST, c);
		if (f.startsWith(DIST) && fs.existsSync(f) && fs.statSync(f).isFile()) return f;
	}
	return null;
}

const idCache = new Map();
function idsOf(file) {
	if (!idCache.has(file)) {
		const html = fs.readFileSync(file, 'utf8');
		idCache.set(file, new Set([...html.matchAll(/\s(?:id|name)="([^"]*)"/g)].map((m) => decode(m[1]))));
	}
	return idCache.get(file);
}

const pages = walk(DIST).filter((f) => f.endsWith('.html'));
const failures = [];
let checked = 0;
for (const page of pages) {
	const html = fs.readFileSync(page, 'utf8');
	const urls = [];
	for (const m of html.matchAll(/\s(href|src)="([^"]*)"/g)) urls.push(decode(m[2]));
	for (const m of html.matchAll(/\ssrcset="([^"]*)"/g)) {
		for (const part of decode(m[1]).split(',')) urls.push(part.trim().split(/\s+/)[0]);
	}
	for (const url of urls) {
		if (!url.startsWith(BASE) && url !== BASE.slice(0, -1)) continue;
		checked++;
		const [beforeHash, fragment] = url.split('#');
		const urlPath = beforeHash.split('?')[0];
		const target = resolve(urlPath === BASE.slice(0, -1) ? BASE : urlPath);
		const where = path.relative(DIST, page).replace(/\\/g, '/');
		if (!target) {
			failures.push(`${where}: ${url} (no such file in dist/)`);
			continue;
		}
		if (checkAnchors && fragment && target.endsWith('.html') && !idsOf(target).has(decodeURIComponent(fragment))) {
			failures.push(`${where}: ${url} (no id="${fragment}" in ${path.relative(DIST, target).replace(/\\/g, '/')})`);
		}
	}
}

if (failures.length) {
	console.error(`[check-links] ${failures.length} broken internal link(s):`);
	for (const f of failures) console.error(`  ${f}`);
	process.exit(1);
}
console.log(`[check-links] ${checked} internal links in ${pages.length} pages, all resolve`);
