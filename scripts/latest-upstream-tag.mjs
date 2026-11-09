#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const slug = fs.readFileSync(path.join(root, 'UPSTREAM'), 'utf8').trim();

if (!/^[\w.-]+\/[\w.-]+$/.test(slug)) {
  console.error(`UPSTREAM must contain owner/repo, got: ${slug}`);
  process.exit(1);
}

const headers = {
  Accept: 'application/vnd.github+json',
  'User-Agent': 'astra-gate-portable-packaging',
};
if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

const response = await fetch(`https://api.github.com/repos/${slug}/releases/latest`, { headers });
if (!response.ok) {
  const body = await response.text();
  console.error(`GitHub API returned ${response.status} while resolving the latest release of ${slug}: ${body.trim()}`);
  process.exit(1);
}

const release = await response.json();
if (!release.tag_name) {
  console.error(`The latest release of ${slug} has no tag_name.`);
  process.exit(1);
}
console.log(release.tag_name);
