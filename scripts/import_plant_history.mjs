/**
 * Back-enters a plant history (one planting + monthly check-ins) for a user,
 * using real photos and the dates they were actually taken.
 *
 *   cd scripts && node import_plant_history.mjs            # dry run, writes nothing
 *   cd scripts && node import_plant_history.mjs --apply   # writes
 *
 * Idempotent: every document and ledger key is derived from the user id, so a
 * second --apply changes nothing. Dates in the future are refused.
 *
 * Records are marked aiModel='manual-import' and carry a ledger note saying
 * they were back-entered, so they stay distinguishable from in-app check-ins.
 * $createdAt on the documents is the import time; Appwrite does not allow that
 * to be set.
 */
import { config } from 'dotenv';
config({ path: new URL('../.env', import.meta.url).pathname });

import { createHash } from 'node:crypto';
import { statSync } from 'node:fs';
import { basename } from 'node:path';
import {
  Client, Databases, Storage, Users, Query, Permission, Role,
} from 'node-appwrite';
import { InputFile } from 'node-appwrite/file';
import { DB_ID } from './schema.mjs';

const APPLY = process.argv.includes('--apply');

const EMAIL = 'govindrajshankar43@gmail.com';
const LAT = 19.121657;
const LNG = 72.830731;
const HEIGHT_CM = 25;
const SPECIES = { code: 'other', name: 'Other' };

// Dates as stated by the user (IST). The last is just after midnight because
// the import is being run on 28 Nov and the date must not be in the future.
const ENTRIES = [
  { file: '/Users/govindraj/Downloads/1st.jpeg', at: '2026-09-28T12:00:00+05:30', kind: 'plant' },
  { file: '/Users/govindraj/Downloads/2nd.png', at: '2026-10-28T12:00:00+05:30', kind: 'verify', monthKey: '2026-10' },
  { file: '/Users/govindraj/Downloads/3rd.png', at: '2026-11-28T00:05:00+05:30', kind: 'verify', monthKey: '2026-11' },
];

const BUCKET = 'tree_photos';
const COL = {
  trees: 'trees', verifications: 'tree_verifications', ledger: 'credit_ledger',
  profiles: 'profiles', species: 'species', config: 'app_config',
};

const client = new Client()
  .setEndpoint(process.env.APPWRITE_ENDPOINT)
  .setProject(process.env.APPWRITE_PROJECT_ID)
  .setKey(process.env.APPWRITE_API_KEY);
const users = new Users(client);
const databases = new Databases(client);
const storage = new Storage(client);

const sha = (s) => createHash('sha1').update(s).digest('hex');
const exists = async (fn) => {
  try { return await fn(); } catch (e) { if (e.code === 404) return null; throw e; }
};

function geohash(lat, lng, precision = 9) {
  const B = '0123456789bcdefghjkmnpqrstuvwxyz';
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let hash = '', isLng = true, bit = 0, ch = 0;
  while (hash.length < precision) {
    if (isLng) {
      const mid = (lngMin + lngMax) / 2;
      if (lng >= mid) { ch = (ch << 1) | 1; lngMin = mid; } else { ch <<= 1; lngMax = mid; }
    } else {
      const mid = (latMin + latMax) / 2;
      if (lat >= mid) { ch = (ch << 1) | 1; latMin = mid; } else { ch <<= 1; latMax = mid; }
    }
    isLng = !isLng;
    if (++bit === 5) { hash += B[ch]; bit = 0; ch = 0; }
  }
  return hash;
}

async function main() {
  const now = Date.now();
  for (const e of ENTRIES) {
    if (new Date(e.at).getTime() > now) {
      throw new Error(`Refusing: ${e.at} is in the future (${basename(e.file)}).`);
    }
    e.size = statSync(e.file).size; // throws if the file is missing
    if (e.size > 12 * 1024 * 1024) throw new Error(`${e.file} is over the 12 MB bucket limit.`);
  }

  const found = await users.list([Query.equal('email', EMAIL), Query.limit(1)]);
  const user = found.users[0];
  if (!user) throw new Error(`No account for ${EMAIL}. Sign up in the app first.`);
  const uid = user.$id;

  const profile = await exists(() => databases.getDocument(DB_ID, COL.profiles, uid));
  if (!profile) throw new Error('That user has no profile document yet. Open the app once and sign in.');

  const species = await exists(() => databases.getDocument(DB_ID, COL.species, SPECIES.code));
  if (!species) throw new Error("Species 'other' is not seeded. Run: cd scripts && npm run seed");

  const cfgRows = (await databases.listDocuments(DB_ID, COL.config, [Query.limit(200)])).documents;
  const cfg = Object.fromEntries(cfgRows.map((r) => {
    let v = r.value;
    try { v = JSON.parse(r.value); } catch { /* plain string */ }
    return [r.key, v];
  }));
  const plantCredits = Number(cfg['tree.plant_credits'] ?? 5);
  const perVerify = Number(species.creditsPerVerification ?? cfg['tree.credits_per_verification'] ?? 10);
  const vestingMonths = Number(cfg['tree.vesting_months'] ?? 12);
  const co2Per = Math.round(Number(species.co2PerYearGrams ?? 18000) / 12);

  const treeId = `imp_${uid}`.slice(0, 36);
  const first = ENTRIES[0];
  const last = ENTRIES[ENTRIES.length - 1];
  const verifies = ENTRIES.filter((e) => e.kind === 'verify');
  const nextOpen = new Date(last.at); nextOpen.setUTCMonth(nextOpen.getUTCMonth() + 1);
  const nextClose = new Date(nextOpen); nextClose.setUTCDate(nextClose.getUTCDate() + 7);

  const fileIdFor = (e) => `imp_${sha(uid + basename(e.file)).slice(0, 28)}`;
  const verifyIdFor = (e) => `impv_${sha(treeId + e.monthKey).slice(0, 28)}`;
  const perm = [Permission.read(Role.user(uid))];

  const plan = {
    user: { id: uid, email: user.email, creditsBefore: profile.creditsAvailable ?? 0 },
    tree: {
      $id: treeId, ownerId: uid, speciesCode: SPECIES.code, speciesName: SPECIES.name,
      lat: LAT, lng: LNG, plantedAt: new Date(first.at).toISOString(), status: 'alive',
      verificationCount: verifies.length, heightCm: HEIGHT_CM,
      creditsVested: perVerify * verifies.length, vestingMonths,
      lastVerifiedAt: new Date(last.at).toISOString(), nextVerifyAfter: nextOpen.toISOString(),
      plantPhotoFileId: fileIdFor(first), aiModel: 'manual-import',
    },
    verifications: verifies.map((e) => ({
      $id: verifyIdFor(e), monthKey: e.monthKey, photoFileId: fileIdFor(e),
      verifiedAt: new Date(e.at).toISOString(), status: 'approved',
      creditsAwarded: perVerify, heightCm: HEIGHT_CM, aiModel: 'manual-import',
    })),
    ledger: [
      { key: `import:tree_plant:${treeId}`, delta: plantCredits, source: 'tree_plant', at: first.at },
      ...verifies.map((e) => ({
        key: `import:tree_verify:${treeId}:${e.monthKey}`, delta: perVerify,
        source: 'tree_verify', at: e.at, refId: verifyIdFor(e),
      })),
    ],
    files: ENTRIES.map((e) => ({ id: fileIdFor(e), path: e.file, bytes: e.size })),
    totalCredits: plantCredits + perVerify * verifies.length,
  };

  console.log(JSON.stringify(plan, null, 2));
  if (!APPLY) {
    console.log('\nDRY RUN: nothing was written. Re-run with --apply to write.');
    return;
  }

  // 1. Photos
  for (const e of ENTRIES) {
    const id = fileIdFor(e);
    if (await exists(() => storage.getFile(BUCKET, id))) continue;
    await storage.createFile(BUCKET, id, InputFile.fromPath(e.file, basename(e.file)), perm);
    console.log('uploaded', basename(e.file), '->', id);
  }

  // 2. Planting
  const treeDoc = {
    ownerId: uid, speciesCode: SPECIES.code, speciesName: SPECIES.name, nickname: '',
    lat: LAT, lng: LNG, geohash: geohash(LAT, LNG, 9), accuracyM: 5, addressLabel: '',
    plantPhotoFileId: fileIdFor(first), plantPhash: '',
    plantedAt: new Date(first.at).toISOString(), status: 'alive', rejectReason: '',
    verificationCount: verifies.length, consecutiveMisses: 0, heightCm: HEIGHT_CM,
    creditsVested: perVerify * verifies.length, creditsPending: 0, vestingMonths,
    nextVerifyAfter: nextOpen.toISOString(), verifyWindowEnd: nextClose.toISOString(),
    lastVerifiedAt: new Date(last.at).toISOString(),
    mockLocationDetected: false, deviceIntegrityOk: true,
    markerCode: `DT-IMP${sha(treeId).slice(0, 5).toUpperCase()}`,
    aiVerdict: 'Back-entered import of real photos; not verified by the vision model.',
    aiConfidence: 0, aiModel: 'manual-import',
  };
  if (!(await exists(() => databases.getDocument(DB_ID, COL.trees, treeId)))) {
    await databases.createDocument(DB_ID, COL.trees, treeId, treeDoc, perm);
    console.log('created tree', treeId);
  }

  // 3. Check-ins
  for (const e of verifies) {
    const id = verifyIdFor(e);
    if (await exists(() => databases.getDocument(DB_ID, COL.verifications, id))) continue;
    await databases.createDocument(DB_ID, COL.verifications, id, {
      treeId, userId: uid, monthKey: e.monthKey, photoFileId: fileIdFor(e), phash: '',
      lat: LAT, lng: LNG, accuracyM: 5, distanceM: 0, labels: '[]', plantConfidence: 1,
      heightCm: HEIGHT_CM, status: 'approved', rejectReason: '', creditsAwarded: perVerify,
      mockLocationDetected: false, deviceIntegrityOk: true, phashDistanceToNearest: 64,
      aiVerdict: 'Back-entered import of real photos; not verified by the vision model.',
      aiConfidence: 0, aiModel: 'manual-import', verifiedAt: new Date(e.at).toISOString(),
    }, perm);
    console.log('created check-in', e.monthKey);
  }

  // 4. Ledger first (the unique key is the guard), then the cached profile totals.
  let p = await databases.getDocument(DB_ID, COL.profiles, uid);
  let applied = 0;
  for (const row of plan.ledger) {
    const balanceAfter = (p.creditsAvailable ?? 0) + row.delta;
    try {
      await databases.createDocument(DB_ID, COL.ledger, 'unique()', {
        userId: uid, delta: row.delta, balanceAfter, source: row.source,
        refId: row.refId ?? treeId, idempotencyKey: row.key,
        note: 'Back-entered import of real plant photos',
        occurredAt: new Date(row.at).toISOString(),
      }, perm);
    } catch (e) {
      if (e.code === 409) { console.log('ledger already has', row.key); continue; }
      throw e;
    }
    const lifetime = (p.creditsLifetime ?? 0) + row.delta;
    const xp = (p.xp ?? 0) + row.delta;
    const patch = { creditsAvailable: balanceAfter, creditsLifetime: lifetime, xp };
    if (row.source === 'tree_plant') {
      patch.treesPlanted = (p.treesPlanted ?? 0) + 1;
      patch.treesAlive = (p.treesAlive ?? 0) + 1;
    } else {
      patch.co2OffsetGrams = (p.co2OffsetGrams ?? 0) + co2Per;
    }
    p = await databases.updateDocument(DB_ID, COL.profiles, uid, patch);
    applied += row.delta;
  }
  const lastAt = new Date(last.at).toISOString();
  if (!p.lastVerifyAt || new Date(p.lastVerifyAt) < new Date(lastAt)) {
    await databases.updateDocument(DB_ID, COL.profiles, uid, {
      lastVerifyAt: lastAt,
      streakCount: Math.max(p.streakCount ?? 0, verifies.length),
      longestStreak: Math.max(p.longestStreak ?? 0, verifies.length),
    });
  }
  console.log(`\nDone. Credits added this run: ${applied}`);
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
