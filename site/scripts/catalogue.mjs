// Step 2: src/data/catalogue.json, the data behind the landing page's plugin cards.
//
// Shape:
// {
//   serial: <index.json serial>,
//   categories: ["gameplay", "graphics", ...],          // every category in use, sorted
//   plugins: [{
//     id, name, authors[], description, categories[], kind ("client-only" | "content"),
//     permissions: { unsafe: bool, filesystem: "none" | ... },
//     version, released ("YYYY-MM-DD"), melange (range, e.g. ">=0.3.5"), melangeMin ("0.3.5" | null),
//     url (zip), sha256, size (bytes), sizeLabel ("442 KB"), licence, homepage,
//     link ("/melange-plugins/plugins/<id>/"), screenshots: [{ src, caption }], imports: [...]
//   }]                                                    // sorted by name
// }
import path from 'node:path';
import { BASE, DATA_DIR, Report, formatSize, isMain, minVersion, runStandalone, writeFile } from './lib/common.mjs';
import { loadPlugins } from './lib/plugins-data.mjs';

export const CATALOGUE_FILE = path.join(DATA_DIR, 'catalogue.json');

export function buildCatalogue(index, plugins) {
	const list = plugins
		.map((p) => {
			const v = p.latest;
			return {
				id: p.id,
				name: p.name,
				authors: p.authors,
				description: p.description,
				categories: p.categories,
				kind: v.kind,
				permissions: { unsafe: Boolean(v.permissions?.unsafe), filesystem: v.permissions?.filesystem ?? 'none' },
				version: v.version,
				released: v.released,
				melange: v.melange,
				melangeMin: minVersion(v.melange),
				url: v.url,
				sha256: v.sha256,
				size: v.size,
				sizeLabel: formatSize(v.size),
				licence: p.licence,
				homepage: p.homepage,
				link: `${BASE}/plugins/${p.id}/`,
				screenshots: p.screenshots.map((s) => ({ src: `${BASE}/plugins/${p.id}/screenshots/${s.file}`, caption: s.caption })),
				imports: p.imports,
			};
		})
		.sort((a, b) => a.name.localeCompare(b.name));
	return {
		serial: index.serial,
		categories: [...new Set(list.flatMap((p) => p.categories))].sort(),
		plugins: list,
	};
}

export async function main({ write = true, data } = {}) {
	const report = new Report('catalogue');
	const { index, plugins } = data ?? loadPlugins(report);
	const catalogue = buildCatalogue(index, plugins);
	if (write) writeFile(CATALOGUE_FILE, JSON.stringify(catalogue, null, 2) + '\n');
	report.summary(`${write ? 'wrote' : 'checked'} src/data/catalogue.json: ${catalogue.plugins.length} plugins, ${catalogue.categories.length} categories`);
	return report;
}

if (isMain(import.meta.url)) runStandalone(main);
