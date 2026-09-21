// Read exported copies, never Photos internals. Reports live outside the export.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const mediaExtensions = new Set(['jpeg', 'jpg', 'heic', 'png', 'mov', 'mp4']);
const photoExtensions = new Set(['jpeg', 'jpg', 'heic', 'png']);
const increment = (counts, key) => { counts[key] = (counts[key] ?? 0) + 1; };

export function captureDate(metadata, isPhoto) {
  // Keep unknown time zones unknown. File modification/creation time is export time.
  const fields = isPhoto ? ['DateTimeOriginal', 'CreateDate'] : ['DateTimeOriginal', 'CreationDate', 'MediaCreateDate', 'CreateDate'];
  for (const source of fields) {
    const value = metadata[source];
    if (typeof value !== 'string') continue;
    const match = /^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/.exec(value);
    if (!match) continue;
    const [, year, month, day, hour, minute, second] = match.map(Number);
    const check = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
    if (year < 1900 || month !== check.getUTCMonth() + 1 || day !== check.getUTCDate()
        || hour > 23 || minute > 59 || second > 59) continue;
    return { source, value, day: `${match[1]}-${match[2]}-${match[3]}`,
      offset: metadata.OffsetTimeOriginal ?? value.match(/([+-]\d{2}:\d{2}|Z)$/)?.[1] ?? null };
  }
  return null;
}

export function coordinates(metadata) {
  let latitude = metadata.GPSLatitude, longitude = metadata.GPSLongitude;
  if (typeof latitude === 'number' && metadata.GPSLatitudeRef === 'S') latitude = -Math.abs(latitude);
  if (typeof longitude === 'number' && metadata.GPSLongitudeRef === 'W') longitude = -Math.abs(longitude);
  return typeof latitude === 'number' && typeof longitude === 'number'
    && Number.isFinite(latitude) && Number.isFinite(longitude)
    && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180
    ? { latitude, longitude } : null;
}

function walk(root) {
  const files = [], skipped = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.name.startsWith('.')) continue;
      const file = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) { skipped.push(path.relative(root, file)); continue; }
      if (entry.isDirectory()) visit(file);
      else if (entry.isFile()) {
        const stat = fs.statSync(file);
        files.push({ path: path.relative(root, file), bytes: stat.size, modified: stat.mtimeMs });
      }
    }
  }
  visit(root);
  return { files: files.sort((a, b) => a.path.localeCompare(b.path, 'en')), skipped };
}

async function hash(file) {
  const value = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) value.update(chunk);
  return value.digest('hex');
}

export function summarize(rows) {
  const formats = {}, months = {}, folders = {}, hashes = new Map();
  for (const row of rows) {
    increment(formats, row.extension);
    increment(months, row.capture?.day.slice(0, 7) ?? 'unknown');
    const group = folders[row.folder] ??= { files: 0, photos: 0, gpsPhotos: 0, dates: new Set(), bytes: 0 };
    group.files++; group.bytes += row.bytes;
    if (row.isPhoto) { group.photos++; if (row.gps) group.gpsPhotos++; }
    if (row.capture) group.dates.add(row.capture.day);
    const copies = hashes.get(row.sha256) ?? [];
    copies.push(row.path); hashes.set(row.sha256, copies);
  }
  const photos = rows.filter(row => row.isPhoto);
  const duplicates = [...hashes.values()].filter(copies => copies.length > 1);
  return { files: rows.length, photos: photos.length, videos: rows.length - photos.length,
    bytes: rows.reduce((sum, row) => sum + row.bytes, 0), formats, months,
    photosWithCaptureDate: photos.filter(row => row.capture).length,
    photosWithExplicitOffset: photos.filter(row => row.capture?.offset).length,
    photosWithGPS: photos.filter(row => row.gps).length,
    photosWithTitleOrDescription: photos.filter(row => row.title || row.description).length,
    photosWithKeywords: photos.filter(row => row.keywords).length,
    metadataErrors: rows.filter(row => row.metadataError).length,
    exactDuplicateGroups: duplicates.length, redundantCopies: duplicates.reduce((sum, copies) => sum + copies.length - 1, 0),
    uniqueFiles: hashes.size, duplicates,
    folders: Object.entries(folders).map(([folder, value]) => ({ folder, ...value, dates: [...value.dates].sort() }))
      .sort((a, b) => b.photos - a.photos || a.folder.localeCompare(b.folder, 'en')) };
}

export async function audit(rootArgument, outputArgument) {
  const root = fs.realpathSync(rootArgument);
  const output = path.resolve(outputArgument);
  const inside = (candidate) => candidate === root || candidate.startsWith(root + path.sep);
  if (inside(output)) throw new Error('Output must be outside the read-only export.');
  if (fs.existsSync(output)) throw new Error('Output exists; choose a new run directory.');
  const parent = fs.realpathSync(path.dirname(output));
  if (inside(parent)) throw new Error('Output parent resolves inside the export.');
  const before = walk(root);
  if (before.skipped.length) throw new Error('Symlinks found; audit a plain export without linked content.');
  const files = before.files.filter(file => mediaExtensions.has(path.extname(file.path).slice(1).toLowerCase()));
  if (!files.length) throw new Error('No supported media found.');
  const raw = execFileSync('exiftool', ['-json', '-n', '-r', ...[...mediaExtensions].flatMap(ext => ['-ext', ext]),
    '-DateTimeOriginal', '-OffsetTimeOriginal', '-CreationDate', '-CreateDate', '-MediaCreateDate',
    '-GPSLatitude', '-GPSLongitude', '-GPSLatitudeRef', '-GPSLongitudeRef', '-ImageWidth', '-ImageHeight', '-Orientation',
    '-Title', '-Description', '-Keywords', '-Subject', '-ContentIdentifier', '-Warning', '-Error', root],
  { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const metadata = new Map(JSON.parse(raw).map(row => [path.resolve(row.SourceFile), row]));
  const rows = [];
  for (const file of files) {
    const full = path.join(root, file.path);
    const tags = metadata.get(full);
    const extension = path.extname(file.path).slice(1).toLowerCase();
    const isPhoto = photoExtensions.has(extension);
    rows.push({ ...file, folder: path.dirname(file.path), extension, isPhoto,
      sha256: await hash(full), capture: captureDate(tags ?? {}, isPhoto), gps: coordinates(tags ?? {}),
      width: tags?.ImageWidth ?? null, height: tags?.ImageHeight ?? null,
      orientation: tags?.Orientation ?? null, contentIdentifier: tags?.ContentIdentifier ?? null,
      title: tags?.Title ?? null, description: tags?.Description ?? null,
      keywords: tags?.Keywords ?? tags?.Subject ?? null,
      metadataError: tags?.Error ?? (tags ? null : 'No metadata result'), warning: tags?.Warning ?? null });
    if (rows.length % 1000 === 0) process.stderr.write(`Audited ${rows.length}/${files.length} files locally.\n`);
  }
  if (JSON.stringify(before) !== JSON.stringify(walk(root))) throw new Error('Export changed during audit; rerun after export completes.');
  const summary = summarize(rows);
  const notes = [
    'Read-only exported-file audit; no Photos access, no network, no image decoding.',
    'Folder labels are reference hints, not verified events or grouping model inputs.',
    'Favorites, People names, album membership and Photos utility categories are not reconstructed from filenames.',
    'Unknown time zones remain unknown; filesystem timestamps are not capture dates.',
    'Exact duplicate hashes do not identify visually similar re-exports.',
    'Private paths, coordinates and annotations stay in this local report, not source control.',
  ];
  fs.mkdirSync(output, { mode: 0o700 });
  const save = (name, data) => fs.writeFileSync(path.join(output, name), data, { mode: 0o600, flag: 'wx' });
  save('manifest.json', JSON.stringify({ version: 1, root, generated: new Date().toISOString(),
    notes, ignoredFiles: before.files.length - files.length, rows }, null, 2));
  save('summary.json', JSON.stringify(summary, null, 2));
  save('README.md', `# Export Audit\n\n${notes.map(note => `- ${note}`).join('\n')}\n\n`
    + `${summary.photos} photos, ${summary.videos} videos; ${summary.folders.length} media folders.\n`
    + `${summary.photosWithCaptureDate} photos with embedded dates; ${summary.photosWithGPS} with GPS.\n`
    + `${summary.redundantCopies} redundant exact copies in ${summary.exactDuplicateGroups} groups.\n`
    + `No files were removed from the export.\n`);
  // Only aggregate coverage goes to the terminal; never print GPS or photo annotations.
  const { folders, duplicates, ...aggregate } = summary;
  console.log(JSON.stringify({ ...aggregate, folders: folders.length, output }, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (process.argv.length !== 4) throw new Error('Usage: node audit-export.mjs EXPORT_FOLDER NEW_REPORT_FOLDER');
  await audit(process.argv[2], process.argv[3]);
}
