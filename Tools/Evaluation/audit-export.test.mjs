import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { audit, captureDate, coordinates, summarize } from './audit-export.mjs';

test('dates retain uncertainty and never fall back to filesystem export time', () => {
  assert.equal(captureDate({ FileModifyDate: '2026:09:09 23:00:00' }, true), null);
  assert.equal(captureDate({ DateTimeOriginal: '2026:02:30 12:00:00' }, true), null);
  assert.equal(captureDate({ DateTimeOriginal: '0000:00:00 00:00:00' }, true), null);
  const result = captureDate({ DateTimeOriginal: '2026:08:30 16:23:26' }, true);
  assert.equal(result.day, '2026-08-30');
  assert.equal(result.offset, null);
  assert.equal(captureDate({ MediaCreateDate: '2026:08:30 16:23:26' }, false).source, 'MediaCreateDate');
  const movie = captureDate({ CreationDate: '2026:02:08 13:04:46+01:00',
    CreateDate: '2026:09:09 21:31:30', MediaCreateDate: '2026:09:09 21:31:30' }, false);
  assert.equal(movie.day, '2026-02-08');
  assert.equal(movie.offset, '+01:00');
});

test('GPS needs both valid coordinates; zero is not missing', () => {
  assert.equal(coordinates({ GPSLatitude: 52 }), null);
  assert.equal(coordinates({ GPSLatitude: NaN, GPSLongitude: 1 }), null);
  assert.equal(coordinates({ GPSLatitude: 91, GPSLongitude: 1 }), null);
  assert.deepEqual(coordinates({ GPSLatitude: 0, GPSLongitude: -3 }), { latitude: 0, longitude: -3 });
  assert.deepEqual(coordinates({ GPSLatitude: 12, GPSLatitudeRef: 'S', GPSLongitude: 3, GPSLongitudeRef: 'W' }),
    { latitude: -12, longitude: -3 });
});

test('duplicates depend on content hashes, not filename or reference folder', () => {
  const base = { extension: 'jpeg', isPhoto: true, bytes: 12, capture: null, gps: null };
  const summary = summarize([
    { ...base, path: 'first/a.jpeg', folder: 'first', sha256: 'same' },
    { ...base, path: 'second/b.jpeg', folder: 'second', sha256: 'same' },
    { ...base, path: 'second/a.jpeg', folder: 'second', sha256: 'different' },
  ]);
  assert.equal(summary.files, 3);
  assert.equal(summary.uniqueFiles, 2);
  assert.equal(summary.redundantCopies, 1);
  assert.equal(summary.folders.length, 2);
  assert.equal(summary.photosWithCaptureDate, 0);
});

test('output cannot overwrite the export or an existing report', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'export-audit-test-'));
  try {
    await assert.rejects(audit(root, path.join(root, 'report')), /outside|inside/);
    await assert.rejects(audit(root, os.tmpdir()), /exists/);
  } finally { fs.rmdirSync(root); }
});
