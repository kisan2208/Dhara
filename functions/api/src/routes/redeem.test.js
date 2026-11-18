import test from 'node:test';
import assert from 'node:assert/strict';

import { VERIFIED_AT, ocrMatchScore, resubmissionPatch, submitElectricity } from './redeem.js';
import { Rejected } from '../lib/context.js';

// ---------------------------------------------------------------------------
// A small in-memory Appwrite: equality filters and limits are all this route
// uses.
// ---------------------------------------------------------------------------

function fakeDb(seed = {}) {
  const cols = {};
  for (const [c, docs] of Object.entries(seed)) {
    cols[c] = new Map(docs.map((d) => [d.$id, { ...d }]));
  }
  const col = (c) => (cols[c] ??= new Map());
  let n = 0;
  return {
    cols,
    rows: (c) => [...col(c).values()],
    getDocument: async (_db, c, id) => {
      const d = col(c).get(id);
      if (!d) throw Object.assign(new Error('not found'), { code: 404 });
      return { ...d };
    },
    createDocument: async (_db, c, id, data) => {
      const realId = id === 'unique()' ? `gen${++n}` : id;
      const doc = { $id: realId, ...data };
      col(c).set(realId, doc);
      return { ...doc };
    },
    updateDocument: async (_db, c, id, patch) => {
      const d = col(c).get(id) ?? { $id: id };
      Object.assign(d, patch);
      col(c).set(id, d);
      return { ...d };
    },
    listDocuments: async (_db, c, queries = []) => {
      let docs = [...col(c).values()];
      for (const q of queries) {
        const j = JSON.parse(String(q));
        if (j.method === 'equal') docs = docs.filter((d) => j.values.includes(d[j.attribute]));
      }
      return { documents: docs.map((d) => ({ ...d })), total: docs.length };
    },
  };
}

const user = { $id: 'u1' };
const CONSUMER = '123456789012';
const readableBill = `ELECTRICITY BILL Consumer No: ${CONSUMER} Amount due 1,240`;
const blurryBill = 'ELECTRICITY BILL Consumer No: 12?4?6 Amount due';

const body = (ocrExcerpt, fileId = 'bill2') => ({
  consumerNo: CONSUMER,
  provider: 'BESCOM',
  providerCode: 'BESCOM',
  billFileId: fileId,
  ocrExcerpt,
});

const account = (status, extra = {}) => ({
  $id: 'acc1',
  userId: 'u1',
  consumerNo: CONSUMER,
  provider: 'BESCOM',
  providerCode: 'BESCOM',
  billFileId: 'bill1',
  ocrExcerpt: blurryBill,
  ocrMatchScore: 0,
  status,
  rejectReason: status === 'rejected' ? 'Number not readable' : '',
  isPrimary: true,
  ...extra,
});

const seed = (status, extra) => ({
  electricity_accounts: [account(status, extra)],
  profiles: [{ $id: 'u1', electricityVerified: status === 'verified' }],
});

// ---------------------------------------------------------------------------
// Pure rules
// ---------------------------------------------------------------------------

test('the OCR score finds the full number, a long tail, or a short tail', () => {
  assert.equal(ocrMatchScore(CONSUMER, readableBill), 1);
  assert.equal(ocrMatchScore(CONSUMER, 'no: 56789012'), 0.75);
  assert.equal(ocrMatchScore(CONSUMER, 'no: 789012'), 0.5);
  assert.equal(ocrMatchScore(CONSUMER, blurryBill), 0);
  assert.equal(ocrMatchScore(CONSUMER, undefined), 0);
  assert.equal(VERIFIED_AT, 0.75);
});

test('a readable resubmission verifies and clears the old rejection', () => {
  const { verified, patch } = resubmissionPatch(account('rejected'), {
    billFileId: 'bill2',
    ocrExcerpt: readableBill,
  }, '2026-11-20T00:00:00.000Z');
  assert.equal(verified, true);
  assert.equal(patch.status, 'verified');
  assert.equal(patch.rejectReason, '');
  assert.equal(patch.billFileId, 'bill2');
  assert.equal(patch.verifiedAt, '2026-11-20T00:00:00.000Z');
});

test('an unreadable resubmission goes back to review with a reason', () => {
  const { verified, patch } = resubmissionPatch(account('rejected'), {
    billFileId: 'bill2',
    ocrExcerpt: blurryBill,
  });
  assert.equal(verified, false);
  assert.equal(patch.status, 'pending_review');
  assert.ok(patch.rejectReason.length > 0);
  assert.equal(patch.verifiedAt, null);
});

// ---------------------------------------------------------------------------
// The route
// ---------------------------------------------------------------------------

test('a rejected account is re-evaluated with the new photo, not returned as is', async () => {
  const db = fakeDb(seed('rejected'));
  const out = await submitElectricity({ databases: db, user, body: body(readableBill) });

  assert.equal(out.verified, true);
  assert.equal(out.resubmitted, true);
  assert.equal(out.account.status, 'verified');
  assert.equal(out.account.billFileId, 'bill2');
  // Same document updated: still exactly one account for this number.
  assert.equal(db.rows('electricity_accounts').length, 1);
  assert.equal(db.cols.profiles.get('u1').electricityVerified, true);
  assert.equal(db.cols.profiles.get('u1').primaryConsumerNo, CONSUMER);
});

test('a pending account with another unclear photo stays pending and says so', async () => {
  const db = fakeDb(seed('pending_review'));
  const out = await submitElectricity({ databases: db, user, body: body(blurryBill) });

  assert.equal(out.verified, false);
  assert.equal(out.account.status, 'pending_review');
  assert.match(out.message, /queued for review/i);
  assert.equal(db.rows('electricity_accounts').length, 1);
  assert.equal(db.cols.profiles.get('u1').electricityVerified, false);
});

test('a verified account is never downgraded by a later photo', async () => {
  const db = fakeDb(seed('verified', { ocrMatchScore: 1, billFileId: 'bill1' }));
  const out = await submitElectricity({ databases: db, user, body: body(blurryBill) });

  assert.equal(out.verified, true);
  assert.equal(out.alreadyLinked, true);
  const stored = db.cols.electricity_accounts.get('acc1');
  assert.equal(stored.status, 'verified');
  assert.equal(stored.billFileId, 'bill1');
  assert.equal(db.rows('electricity_accounts').length, 1);
});

test('submitting twice creates one account, not two', async () => {
  const db = fakeDb({ profiles: [{ $id: 'u1' }] });
  await submitElectricity({ databases: db, user, body: body(blurryBill, 'billA') });
  await submitElectricity({ databases: db, user, body: body(blurryBill, 'billB') });

  assert.equal(db.rows('electricity_accounts').length, 1);
  assert.equal(db.rows('electricity_accounts')[0].billFileId, 'billB');
});

test('a number held by someone else is still refused', async () => {
  const db = fakeDb({
    electricity_accounts: [account('verified', { userId: 'other' })],
    profiles: [{ $id: 'u1', trustScore: 100 }],
  });
  await assert.rejects(
    submitElectricity({ databases: db, user, body: body(readableBill) }),
    (e) => e instanceof Rejected && e.code === 'consumer_no_taken',
  );
  assert.equal(db.rows('electricity_accounts').length, 1);
});
