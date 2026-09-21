import fs from 'node:fs';
import path from 'node:path';

const output = path.resolve(process.argv[2]);
const manifest = JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'), 'utf8'));
const photos = manifest.rows.filter(row => row.isPhoto);
// Hold out all February photos together, rather than leaking neighboring Barcelona days.
// Holdout pixels are not rendered or used to tune the initial reference cases.
const heldOut = photos.filter(row => row.capture?.day.startsWith('2026-02'));
const development = photos.filter(row => !heldOut.includes(row));
const definitions = [
  ['C01', 'Haar, January 3, 2026', 16, 'single venue, architecture and people'],
  ['C02', 'Keukenhof, April 6, 2026', 16, 'same outing with varied subjects'],
  ['C03', 'Fontainebleau, July 20, 2026', 20, 'large day beyond the 512-photo refinement limit'],
  ['C04', 'Saint-Tropez, July 28, 2026', 16, 'outdoor travel and scene changes'],
  ['C05', 'Soesterberg, April 25, 2026', 16, 'small outing and contextual details'],
  ['C06', 'August 30, 2026', 30, 'known compressed/interleaved-timeline regression, including separate midday photo'],
  ['C07', 'Home, January 18, 2026', 12, 'ordinary-day photos, no assumed occasion'],
];
function sample(rows, limit) {
  const unique = [...new Map(rows.map(row => [row.sha256, row])).values()]
    .sort((a, b) => (a.capture?.value ?? '').localeCompare(b.capture?.value ?? '') || a.path.localeCompare(b.path));
  if (unique.length <= limit) return unique;
  return Array.from({ length: limit }, (_, i) => unique[Math.round(i * (unique.length - 1) / (limit - 1))]);
}
const cases = definitions.map(([id, suffix, limit, purpose]) => {
  const rows = development.filter(row => row.folder.endsWith(suffix));
  if (!rows.length) throw new Error(`No files for ${id}`);
  return { id, purpose, referenceFolders: [...new Set(rows.map(row => row.folder))], available: rows.length,
    samples: sample(rows, limit).map(row => ({ path: row.path, sha256: row.sha256 })) };
});
const utilities = development.filter(row => row.description === 'Screenshot');
cases.push({ id: 'C08', purpose: 'utility-image negative examples; description is an export hint, not PhotoKit category',
  referenceFolders: [], available: utilities.length,
  samples: sample(utilities, 12).map(row => ({ path: row.path, sha256: row.sha256 })) });
const plan = { version: 1, root: manifest.root, consent: 'User approved representative samples in conversation on 2026-09-09.',
  status: 'provisional reference review, not accepted ground truth',
  sampling: 'Evenly spaced by embedded local capture time within development folders; not quality-ranked.',
  leakageGuard: 'Folder titles are reference-only. All February photos reserved before pixel inspection; never tune on the held-out set.',
  heldOut: heldOut.map(row => ({ path: row.path, sha256: row.sha256 })), cases };
fs.writeFileSync(path.join(output, 'reference-sample.json'), JSON.stringify(plan, null, 2), { mode: 0o600, flag: 'wx' });
console.log(JSON.stringify({ samples: cases.reduce((n, c) => n + c.samples.length, 0), heldOut: heldOut.length,
  cases: cases.map(c => ({ id: c.id, available: c.available, sampled: c.samples.length })) }, null, 2));
