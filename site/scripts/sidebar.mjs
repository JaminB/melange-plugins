// The Starlight sidebar, built from ../index.json so a new plugin appears without editing astro.config.mjs.
// Usage in astro.config.mjs:  import { sidebar } from './scripts/sidebar.mjs';  starlight({ sidebar, ... })
// The slugs point at pages written by scripts/prebuild.mjs (plugin-pages, publish-docs, about).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SCHEMA_PAGES } from './publish-docs.mjs';

const REPO_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function pluginEntries() {
	const index = JSON.parse(fs.readFileSync(path.join(REPO_DIR, 'index.json'), 'utf8').replace(/^﻿/, ''));
	return (index.plugins ?? [])
		.filter((p) => (p.versions ?? []).some((v) => !v.yanked))
		.map((p) => ({ label: p.name ?? p.id, slug: `plugins/${p.id}` }))
		.sort((a, b) => a.label.localeCompare(b.label));
}

export const sidebar = [
	{ label: 'Plugins', items: pluginEntries() },
	{
		label: 'Publish a plugin',
		items: [
			{ label: 'How to publish', slug: 'publish' },
			...SCHEMA_PAGES.filter((s) => fs.existsSync(path.join(REPO_DIR, s.file))).map((s) => ({ label: s.label, slug: `publish/${s.slug}` })),
			{ label: 'Policy', slug: 'publish/policy' },
		],
	},
	{ label: 'About', slug: 'about' },
];

export default sidebar;
