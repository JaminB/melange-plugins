// Step 3: one page per plugin, src/content/docs/plugins/<id>.md (served at /melange-plugins/plugins/<id>/), and the
// plugin's README images and screenshots copied to public/plugins/<id>/.
//
// Page = generated header block (categories, kind, permissions, Melange range, download, licence, source), the
// README with its H1 stripped, optional Screenshots, then "Versions" with one H3 per released version.
import path from 'node:path';
import {
	BASE, DOCS_DIR, PUBLIC_DIR, REPO_DIR, Report, cleanDir, copyFile, demoteHeadings, describeRange, editUrl,
	escapeHtml, escapeStrayAngles, formatSize, frontmatter, isMain, blobUrl, rewriteLinks, runStandalone,
	sitePageMap, stripH1, treeUrl, truncate, writeFile,
} from './lib/common.mjs';
import { loadPlugins } from './lib/plugins-data.mjs';

export const PAGES_DIR = path.join(DOCS_DIR, 'plugins');
export const ASSETS_DIR = path.join(PUBLIC_DIR, 'plugins');

const RAW_URL = 'https://raw.githubusercontent.com/JaminB/melange-plugins/main';

// Codename glyph shown in a category chip (the CSS masks live in src/styles/theme.css). Keep in sync with
// src/components/PluginCard.astro.
const CATEGORY_GLYPHS = { gameplay: 'thumper', graphics: 'mirage', maps: 'erg', audio: 'oasis', tools: 'sieve' };
const glyph = (name) => `<span class="mel-glyph" data-glyph="${name}" aria-hidden="true"></span>`;
const DOWNLOAD_ICON =
	'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12M6.5 10l5.5 5.5 5.5-5.5M4 20h16"/></svg>';

// The header block is raw HTML inside the .md page (one block, no blank lines, so Markdown leaves it alone). Its
// classes come from the shared theme (src/styles/theme.css: .mel-chip, .mel-pill, .mel-cta, .mel-sha, .mel-copy) and
// src/styles/site.css (.mel-plugin-header, .mel-facts). The Copy button is wired up by src/components/Footer.astro.
function headerBlock(p) {
	const v = p.latest;
	const perms = v.permissions ?? {};
	const chips = [
		...p.categories.map((c) => `<li class="mel-chip mel-chip--cat">${glyph(CATEGORY_GLYPHS[c] ?? 'spice')}${escapeHtml(c)}</li>`),
		`<li class="mel-chip">${escapeHtml(v.kind)}</li>`,
		perms.unsafe
			? `<li class="mel-chip mel-chip--deep">${glyph('deep-desert')}<abbr title="Can patch raw game memory">Deep Desert</abbr><span class="sr-only">: can patch raw game memory</span></li>`
			: '<li class="mel-chip">Sandboxed: no raw memory access</li>',
	];
	if (perms.filesystem && perms.filesystem !== 'none') {
		chips.push(`<li class="mel-chip">Files: ${escapeHtml(perms.filesystem)}</li>`);
	}
	const facts = [
		['Needs', `Melange ${escapeHtml(describeRange(v.melange))} <code>${escapeHtml(v.melange)}</code>`],
		['Install', 'In the game, press <kbd>`</kbd> and open <strong>Thumper &gt; Store</strong>'],
		['Authors', escapeHtml(p.authors.join(', '))],
		['Licence', p.hasLicense ? `<a href="${blobUrl(`${p.repoDir}/LICENSE`)}">${escapeHtml(p.licence)}</a>` : escapeHtml(p.licence ?? '')],
		['Source', `<a href="${treeUrl(p.repoDir)}">${escapeHtml(`plugins/${p.id}`)} on GitHub</a>`],
	];
	if (p.homepage && !p.homepage.startsWith(treeUrl(p.repoDir))) {
		facts.push(['Homepage', `<a href="${escapeHtml(p.homepage)}">${escapeHtml(p.homepage.replace(/^https:\/\//, ''))}</a>`]);
	}
	for (const imp of p.imports) {
		facts.push([
			'Imports',
			`${escapeHtml(imp.title)} from ${escapeHtml(imp.publisher)} (${
				imp.host && imp.host !== imp.publisher ? `${escapeHtml(imp.host)}, ` : ''
			}${formatSize(imp.size)}), downloaded on your PC`,
		]);
	}
	const zip = v.url.split('/').pop();
	const lines = [
		'<div class="mel-plugin-header not-content">',
		'<div class="mel-plugin-header__meta">',
		`<span class="mel-pill">v${escapeHtml(v.version)}</span>`,
		`<span>Latest, released <time datetime="${escapeHtml(v.released)}">${escapeHtml(v.released)}</time></span>`,
		'</div>',
		`<ul class="mel-chips" aria-label="Categories and permissions">${chips.join('')}</ul>`,
		`<section class="mel-dl mel-plugin-dl" aria-label="Download ${escapeHtml(p.name)}">`,
		'<div class="mel-cta-wrap">',
		'<span class="mel-ripple" aria-hidden="true"><i></i><i></i><i></i></span>',
		`<a class="mel-cta" href="${escapeHtml(v.url)}" download>${DOWNLOAD_ICON}<span>` +
			`<span class="mel-cta__label">Download ${escapeHtml(p.name)} ${escapeHtml(v.version)}</span>` +
			`<span class="mel-cta__file">${escapeHtml(zip)} · ${formatSize(v.size)}</span></span></a>`,
		'</div>',
		'<dl class="mel-sha">',
		'<dt class="mel-sha__label">SHA-256</dt>',
		`<dd class="mel-sha__row"><code class="mel-sha__value">${escapeHtml(v.sha256)}</code>` +
			'<button class="mel-copy" type="button" aria-label="Copy SHA-256" data-mel-copy>Copy</button>' +
			'<span class="sr-only" role="status"></span></dd>',
		'</dl>',
		'<p class="mel-dl__req">The Store in the game installs and updates it for you; the zip is for installing by hand.</p>',
		'</section>',
		'<dl class="mel-facts">',
		...facts.map(([k, val]) => `<dt>${k}</dt><dd>${val}</dd>`),
		'</dl>',
		'</div>',
		'',
	];
	if (perms.unsafe) {
		lines.push(
			':::danger[Deep Desert]',
			'This plugin asks for raw memory access (**Deep Desert**). Melange asks for your consent in the game before it runs, ' +
				'and again every time its code changes. Only allow it if you trust the author.',
			':::',
			'',
		);
	}
	return lines.join('\n');
}

function versionsSection(p, report) {
	const out = ['## Versions', ''];
	for (const v of p.versions) {
		const zip = v.url.split('/').pop();
		out.push(`### ${v.version}${v.yanked ? ' (yanked)' : ''}`, '');
		out.push(`Released ${v.released} · Melange ${describeRange(v.melange)} · [${zip}](${v.url}) (${formatSize(v.size)})`, '');
		out.push(`SHA-256 \`${v.sha256}\``, '');
		if (v.yanked) out.push('**Yanked**: withdrawn from the Store; do not install this version.', '');
		let notes;
		if (p.changelog[v.version] !== undefined) notes = demoteHeadings(p.changelog[v.version], 1);
		else {
			if (Object.keys(p.changelog).length) report.warn(`${p.id}: CHANGELOG.md has no "## ${v.version}" section; using index.json's changelog`);
			notes = demoteHeadings(v.changelog ?? '', 3);
		}
		if (notes.trim()) out.push(escapeStrayAngles(notes.trim()), '');
	}
	return out.join('\n');
}

export function renderPluginPage(p, { pageMap, report, onAsset }) {
	const { body } = stripH1(p.readme);
	const copyAsset = (repoRel) => {
		const inPlugin = repoRel.startsWith(`${p.repoDir}/`);
		if (!inPlugin) return `${RAW_URL}/${repoRel}`;
		const sub = repoRel.slice(p.repoDir.length + 1);
		onAsset(path.join(REPO_DIR, ...repoRel.split('/')), path.join(ASSETS_DIR, p.id, ...sub.split('/')));
		return `${BASE}/plugins/${p.id}/${sub}`;
	};
	const readme = escapeStrayAngles(rewriteLinks(body, { fromDir: p.repoDir, pageMap, copyAsset, report })).trim();

	const parts = [
		frontmatter({
			title: p.name,
			description: truncate(p.description.replace(/\s+/g, ' '), 160),
			editUrl: editUrl(`${p.repoDir}/README.md`),
			lastUpdated: new Date(`${p.latest.released}T00:00:00Z`),
		}),
		`<!-- Generated by site/scripts/plugin-pages.mjs from index.json and plugins/${p.id}/. Do not edit. -->`,
		'',
		headerBlock(p),
		readme,
		'',
	];
	if (p.screenshots.length) {
		parts.push('## Screenshots', '');
		for (const s of p.screenshots) {
			onAsset(s.abs, path.join(ASSETS_DIR, p.id, 'screenshots', s.file));
			parts.push(`![${s.caption.replace(/[[\]]/g, '')}](${BASE}/plugins/${p.id}/screenshots/${s.file})`, '');
			if (s.caption) parts.push(`*${s.caption}*`, '');
		}
	}
	parts.push(versionsSection(p, report));
	return parts.join('\n');
}

export async function main({ write = true, data } = {}) {
	const report = new Report('plugin-pages');
	const { plugins } = data ?? loadPlugins(report);
	const pageMap = sitePageMap(plugins.map((p) => p.id));
	if (write) {
		cleanDir(PAGES_DIR);
		cleanDir(ASSETS_DIR);
	}
	let assets = 0;
	const onAsset = (from, to) => {
		assets++;
		if (write) copyFile(from, to);
	};
	for (const p of plugins) {
		const md = renderPluginPage(p, { pageMap, report, onAsset });
		if (write) writeFile(path.join(PAGES_DIR, `${p.id}.md`), md);
	}
	report.summary(`${write ? 'wrote' : 'checked'} ${plugins.length} plugin pages in src/content/docs/plugins/, ${assets} images in public/plugins/`);
	return report;
}

if (isMain(import.meta.url)) runStandalone(main);
