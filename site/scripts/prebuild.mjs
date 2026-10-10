// Generates everything the plugins site builds from. Run by `npm run build` / `npm run dev` before Astro.
//
//   node scripts/prebuild.mjs           write all generated content (each step cleans its own output first)
//   node scripts/prebuild.mjs --check   drift check only, writes nothing: every plugin in index.json has a README.md
//                                       and store.json, and the catalogue and every page generate without error
//
// Steps (each also runnable on its own, e.g. `node scripts/catalogue.mjs`):
//   catalogue.mjs     src/data/catalogue.json
//   plugin-pages.mjs  src/content/docs/plugins/<id>.md, public/plugins/<id>/
//   publish-docs.mjs  src/content/docs/publish/*.md
//   about.mjs         src/content/docs/about.md
// All of it is gitignored (see site/.gitignore). Exit code is non-zero on any hard error.
import { HardError, Report } from './lib/common.mjs';
import { loadPlugins } from './lib/plugins-data.mjs';
import * as catalogue from './catalogue.mjs';
import * as pluginPages from './plugin-pages.mjs';
import * as publishDocs from './publish-docs.mjs';
import * as about from './about.mjs';

const check = process.argv.includes('--check');
const write = !check;

try {
	const report = new Report('plugins');
	const data = loadPlugins(report);
	report.summary(`read index.json: ${data.plugins.length} plugins (serial ${data.index.serial}), README.md and store.json present for each`);
	const reports = [report];
	for (const step of [catalogue, pluginPages, publishDocs, about]) reports.push(await step.main({ write, data }));
	const warnings = reports.reduce((n, r) => n + r.warnings.length, 0);
	console.log(`[prebuild] ${check ? 'check passed' : 'done'}${warnings ? `, ${warnings} warning(s)` : ''}`);
} catch (err) {
	console.error(err instanceof HardError ? `[prebuild] ERROR ${err.message}` : err);
	process.exit(1);
}
