// Loads the store's source of truth (../index.json, what Melange's Store reads) plus each plugin's folder.
import path from 'node:path';
import { REPO_DIR, HardError, readJson, readText, exists, rel } from './common.mjs';

/** Compares dotted numeric versions ("1.10.0" > "1.9.2"); a pre-release suffix sorts before its release. */
export function compareVersions(a, b) {
	const pa = String(a).split(/[-+]/)[0].split('.').map(Number);
	const pb = String(b).split(/[-+]/)[0].split('.').map(Number);
	for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
		const d = (pa[i] || 0) - (pb[i] || 0);
		if (d) return d;
	}
	return (String(b).includes('-') ? 1 : 0) - (String(a).includes('-') ? 1 : 0);
}

/** Splits a CHANGELOG.md into { "<version>": markdown } by its "## <version>" headings. */
export function changelogSections(md) {
	const sections = {};
	const re = /^## +\[?v?([0-9][^\]\s]*)\]?.*$/gm;
	const marks = [...md.matchAll(re)];
	marks.forEach((m, i) => {
		const end = i + 1 < marks.length ? marks[i + 1].index : md.length;
		sections[m[1]] = md.slice(m.index + m[0].length, end).trim();
	});
	return sections;
}

/**
 * @param {import('./common.mjs').Report} report
 * @returns {{index: object, plugins: object[]}}
 */
export function loadPlugins(report) {
	const index = readJson(path.join(REPO_DIR, 'index.json'));
	if (!Array.isArray(index.plugins)) throw new HardError('index.json has no plugins[] array');
	const errors = [];
	const plugins = [];
	for (const entry of index.plugins) {
		const id = entry.id;
		const dir = path.join(REPO_DIR, 'plugins', id ?? '');
		if (!id || !/^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$/.test(id)) {
			errors.push(`index.json lists a plugin with an invalid id ${JSON.stringify(id)}`);
			continue;
		}
		const need = { 'store.json': path.join(dir, 'store.json'), 'README.md': path.join(dir, 'README.md') };
		const missing = Object.entries(need).filter(([, f]) => !exists(f)).map(([n]) => n);
		if (missing.length) {
			errors.push(`plugins/${id}/ is missing ${missing.join(' and ')}`);
			continue;
		}
		let store;
		try {
			store = readJson(need['store.json']);
		} catch (err) {
			errors.push(err.message);
			continue;
		}
		const readme = readText(need['README.md']);
		const changelogFile = path.join(dir, 'CHANGELOG.md');
		const changelog = exists(changelogFile) ? changelogSections(readText(changelogFile)) : {};
		const licenseFile = path.join(dir, 'LICENSE');
		if (!exists(licenseFile)) report.warn(`plugins/${id}/LICENSE is missing`);

		const versions = (Array.isArray(entry.versions) ? entry.versions : []).slice().sort((a, b) => compareVersions(b.version, a.version));
		const live = versions.filter((v) => !v.yanked);
		if (!live.length) {
			errors.push(`${id}: index.json has no released (non-yanked) version`);
			continue;
		}
		const storeVersions = new Set((store.versions ?? []).map((v) => v.version));
		const indexVersions = new Set(versions.map((v) => v.version));
		if (storeVersions.size !== indexVersions.size || [...indexVersions].some((v) => !storeVersions.has(v))) {
			report.warn(`${id}: store.json versions[] and index.json differ (is index.json stale?)`);
		}

		// Screenshots: index.json's entries carry the repo path; store.json names files in plugins/<id>/screenshots/.
		const captions = new Map((store.screenshots ?? []).map((s) => [s.file, s.caption]));
		const shotPaths = (entry.screenshots ?? []).length
			? entry.screenshots.map((s) => ({ repoRel: path.posix.normalize(String(s.path ?? '').replace(/^\/+/, '')), caption: s.caption }))
			: (store.screenshots ?? []).map((s) => ({ repoRel: path.posix.normalize(`plugins/${id}/screenshots/${s.file}`), caption: s.caption }));
		const screenshots = [];
		for (const s of shotPaths) {
			// Both files are contributor-written; a "../" in them must not publish a file from outside the plugin.
			if (!s.repoRel.startsWith(`plugins/${id}/`)) {
				errors.push(`${id}: screenshot ${s.repoRel} is outside plugins/${id}/`);
				continue;
			}
			const abs = path.join(REPO_DIR, ...s.repoRel.split('/'));
			if (!exists(abs)) {
				errors.push(`${id}: screenshot ${s.repoRel} is listed but missing`);
				continue;
			}
			const file = path.posix.basename(s.repoRel);
			screenshots.push({ abs, file, caption: s.caption ?? captions.get(file) ?? '' });
		}

		plugins.push({
			id,
			name: entry.name ?? id,
			authors: entry.authors ?? [],
			description: entry.description ?? '',
			homepage: entry.homepage ?? store.homepage,
			licence: entry.licence ?? store.licence,
			categories: entry.categories ?? store.categories ?? [],
			gameBuilds: entry.gameBuilds ?? store.gameBuilds ?? [],
			imports: entry.imports ?? store.imports ?? [],
			versions,
			latest: live[0],
			readme,
			changelog,
			hasLicense: exists(licenseFile),
			screenshots,
			dir,
			repoDir: rel(dir),
		});
	}
	if (errors.length) throw new HardError(`${errors.length} plugin error(s):\n  ${errors.join('\n  ')}`);
	return { index, plugins };
}
