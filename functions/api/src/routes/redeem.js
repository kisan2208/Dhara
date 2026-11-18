import { ID, Query, Permission, Role } from 'node-appwrite';
import { COL, DB, Rejected, nowIso, num, str } from '../lib/context.js';
import { award, flag, notify, recomputeBalance } from '../lib/ledger.js';

/**
 * Redemption is where fraud actually pays off, so it carries the heaviest
 * checks in the system:
 *
 *   - The balance is recomputed from the ledger rather than trusted from the
 *     cached profile field.
 *   - A daily cap limits the damage if an earning exploit is ever found.
 *   - Bill offsets require a verified electricity consumer number.
 *   - The deduction is written as a normal ledger entry with an idempotency
 *     key, so a double tap cannot spend twice.
 */

export async function redeem({ databases, user, body, config }) {
  const rewardId = str(body.rewardId, 64);
  if (!rewardId) throw new Rejected('missing_reward', 'Pick a reward first.');

  let reward;
  try {
    reward = await databases.getDocument(DB, COL.rewards, rewardId);
  } catch (e) {
    if (e.code === 404) {
      throw new Rejected('reward_not_found', 'That reward is no longer offered.');
    }
    throw e;
  }

  if (!reward.isActive) {
    throw new Rejected('reward_inactive', 'That reward is not available right now.');
  }
  if ((reward.stockRemaining ?? 0) <= 0) {
    throw new Rejected('out_of_stock', 'That reward just went out of stock.');
  }

  const profile = await databases.getDocument(DB, COL.profiles, user.$id);
  if (profile.isBanned) {
    throw new Rejected('account_suspended', 'This account is suspended.');
  }

  const cost = num(reward.creditsCost, 0);
  const minRedeem = num(config['redeem.min_credits'], 50);
  if (cost < minRedeem) {
    throw new Rejected('below_minimum', `Minimum redemption is ${minRedeem} credits.`);
  }

  if ((profile.level ?? 1) < num(reward.minLevel, 1)) {
    throw new Rejected(
      'level_locked',
      `This unlocks at level ${reward.minLevel}. You are level ${profile.level ?? 1}.`,
    );
  }

  // The ledger is authoritative; the profile field is only a cache.
  const truth = await recomputeBalance(databases, user.$id);
  if (truth.available !== (profile.creditsAvailable ?? 0)) {
    console.error(
      'balance drift repaired',
      user.$id,
      'cache',
      profile.creditsAvailable,
      'ledger',
      truth.available,
    );
    await databases.updateDocument(DB, COL.profiles, user.$id, {
      creditsAvailable: truth.available,
      creditsLifetime: truth.lifetime,
      creditsSpent: truth.spent,
    });
  }

  if (truth.available < cost) {
    throw new Rejected(
      'insufficient_credits',
      `You need ${cost - truth.available} more credits.`,
      { available: truth.available, required: cost },
    );
  }

  const payload = typeof body.payload === 'object' && body.payload ? body.payload : {};

  // Bill offsets must land on a verified consumer number, otherwise credits
  // could be pushed onto an account the user does not own.
  let consumerNo = null;
  if (reward.type === 'electricity_bill' || reward.requiresElectricityAccount) {
    const requireVerified = config['redeem.require_electricity_verified'] !== false;
    const account = await primaryElectricityAccount(databases, user.$id);

    if (requireVerified && (!account || account.status !== 'verified')) {
      throw new Rejected(
        'electricity_not_verified',
        'Verify your electricity consumer number before redeeming bill credit.',
      );
    }
    consumerNo = account?.consumerNo ?? null;
  }

  // Daily cap across all redemptions.
  const dailyCap = num(config['redeem.daily_credit_cap'], 500);
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  let spentToday = 0;
  try {
    const recent = await databases.listDocuments(DB, COL.redemptions, [
      Query.equal('userId', user.$id),
      Query.greaterThan('requestedAt', since),
      Query.limit(100),
    ]);
    spentToday = recent.documents
      .filter((r) => r.status !== 'cancelled' && r.status !== 'failed')
      .reduce((sum, r) => sum + num(r.creditsSpent, 0), 0);
  } catch (e) {
    console.error('daily cap check failed', e.message);
  }

  if (spentToday + cost > dailyCap) {
    throw new Rejected(
      'daily_cap_reached',
      `Daily redemption limit is ${dailyCap} credits. You have used ${spentToday}.`,
      { spentToday, dailyCap },
    );
  }

  // A stable key per user per reward per minute: protects against double taps
  // without blocking a deliberate second redemption later.
  const minuteBucket = Math.floor(Date.now() / 60000);
  const idempotencyKey = `redeem:${user.$id}:${rewardId}:${minuteBucket}`;

  const spend = await award(databases, {
    userId: user.$id,
    delta: -cost,
    source: 'redemption',
    refId: rewardId,
    idempotencyKey,
    note: `Redeemed ${reward.title}`,
    config,
  });

  if (!spend.applied) {
    throw new Rejected(
      'duplicate_request',
      'That redemption is already being processed.',
    );
  }

  const record = await databases.createDocument(
    DB,
    COL.redemptions,
    ID.unique(),
    {
      userId: user.$id,
      rewardId,
      rewardTitle: reward.title,
      type: reward.type,
      creditsSpent: cost,
      faceValueInr: num(reward.faceValueInr, 0),
      status: 'pending',
      payload: JSON.stringify({
        ...payload,
        consumerNo: consumerNo ? maskTail(consumerNo) : undefined,
      }).slice(0, 2048),
      idempotencyKey,
      requestedAt: nowIso(),
    },
    [Permission.read(Role.user(user.$id))],
  );

  // Best-effort stock decrement. Slight overselling is preferable to blocking
  // a redemption whose credits are already deducted.
  try {
    await databases.updateDocument(DB, COL.rewards, rewardId, {
      stockRemaining: Math.max(0, (reward.stockRemaining ?? 0) - 1),
    });
  } catch (e) {
    console.error('stock decrement failed', e.message);
  }

  await notify(databases, {
    userId: user.$id,
    title: 'Redemption received',
    body:
      reward.type === 'electricity_bill'
        ? `${reward.title} will be applied to your bill within 3 working days.`
        : `${reward.title} is being processed. We will share the code here.`,
    type: 'redemption',
    refId: record.$id,
  });

  return {
    redemption: record,
    creditsSpent: cost,
    balance: spend.balance,
  };
}

function maskTail(value) {
  const s = String(value);
  return s.length <= 4 ? s : `${'*'.repeat(s.length - 4)}${s.slice(-4)}`;
}

async function primaryElectricityAccount(databases, userId) {
  try {
    const res = await databases.listDocuments(DB, COL.electricityAccounts, [
      Query.equal('userId', userId),
      Query.limit(10),
    ]);
    return (
      res.documents.find((d) => d.isPrimary && d.status === 'verified') ||
      res.documents.find((d) => d.status === 'verified') ||
      res.documents[0] ||
      null
    );
  } catch {
    return null;
  }
}

/** OCR match score at or above which a bill verifies the account on its own. */
export const VERIFIED_AT = 0.75;

/**
 * How well the typed consumer number appears in the bill's OCR text, 0..1.
 * Digits only: OCR frequently mangles spacing and dashes.
 */
export function ocrMatchScore(consumerNo, ocrExcerpt) {
  const digitsOnly = (s) => String(s ?? '').replace(/[^0-9]/g, '');
  const target = digitsOnly(consumerNo);
  const haystack = digitsOnly(ocrExcerpt);

  if (target.length >= 6 && haystack.includes(target)) return 1;
  // Leading digits are often a region prefix the OCR drops.
  if (target.length >= 8 && haystack.includes(target.slice(-8))) return 0.75;
  if (target.length >= 6 && haystack.includes(target.slice(-6))) return 0.5;
  return 0;
}

/**
 * The fields a fresh bill photo writes onto an existing, not-yet-verified
 * account. Pure so the rules are testable: a verified outcome clears the old
 * rejection, anything else goes back to the review queue with a reason.
 */
export function resubmissionPatch(account, input, now = nowIso()) {
  const matchScore = ocrMatchScore(account.consumerNo, input.ocrExcerpt);
  const verified = matchScore >= VERIFIED_AT;
  return {
    matchScore,
    verified,
    patch: {
      provider: input.provider || account.provider,
      providerCode:
        input.providerCode ||
        account.providerCode ||
        String(input.provider || '').slice(0, 8).toUpperCase(),
      ...(input.stateName ? { stateName: input.stateName } : {}),
      ...(input.holderName ? { holderName: input.holderName } : {}),
      billFileId: input.billFileId,
      ocrExcerpt: String(input.ocrExcerpt ?? '').slice(0, 2048),
      ocrMatchScore: matchScore,
      status: verified ? 'verified' : 'pending_review',
      rejectReason: verified
        ? ''
        : 'Consumer number not clearly visible in the uploaded bill.',
      submittedAt: now,
      verifiedAt: verified ? now : null,
    },
  };
}

async function reevaluate(databases, user, existing, input) {
  const { matchScore, verified, patch } = resubmissionPatch(existing, input);
  const account = await databases.updateDocument(
    DB,
    COL.electricityAccounts,
    existing.$id,
    patch,
  );

  if (verified) {
    await databases.updateDocument(DB, COL.profiles, user.$id, {
      electricityVerified: true,
      primaryConsumerNo: existing.consumerNo,
    });
  }

  await notify(databases, {
    userId: user.$id,
    title: verified ? 'Electricity account verified' : 'Bill under review',
    body: verified
      ? 'You can now redeem credits against your electricity bill.'
      : 'We could not read your consumer number on the new photo either. Our team will check within 48 hours.',
    type: 'system',
    refId: existing.$id,
  });

  return {
    account,
    verified,
    matchScore,
    resubmitted: true,
    message: verified
      ? 'Verified from your new bill photo.'
      : 'Your new photo is queued for review. Make sure the consumer number is readable.',
  };
}

/**
 * Verifies an electricity consumer number against an uploaded bill.
 *
 * There is no discom API wired up yet, so verification is OCR-based: the number
 * the user typed must actually appear in the text extracted from the bill photo
 * on-device. Typing a number alone proves nothing, and this catches the obvious
 * case of entering someone else's number with an unrelated photo.
 *
 * Anything the OCR cannot confirm is queued for manual review rather than
 * silently accepted.
 */
export async function submitElectricity({ databases, user, body }) {
  const consumerNo = str(body.consumerNo, 40).toUpperCase().replace(/\s+/g, '');
  const provider = str(body.provider, 96);
  const providerCode = str(body.providerCode, 24);
  const billFileId = str(body.billFileId, 64);
  const ocrExcerpt = str(body.ocrExcerpt, 2048);

  if (!consumerNo) {
    throw new Rejected('missing_consumer_no', 'Enter your consumer number.');
  }
  // Real consumer numbers across Indian discoms run roughly 6-20 chars.
  if (!/^[A-Z0-9-]{6,20}$/.test(consumerNo)) {
    throw new Rejected(
      'invalid_consumer_no',
      'That does not look like a valid consumer number. Check your bill.',
    );
  }
  if (!provider) {
    throw new Rejected('missing_provider', 'Select your electricity provider.');
  }
  if (!billFileId) {
    throw new Rejected('missing_bill', 'Upload a photo of your latest bill.');
  }

  // One consumer number per account, enforced by a unique index. Checked here
  // for a clear message.
  let mine = null;
  try {
    const clash = await databases.listDocuments(DB, COL.electricityAccounts, [
      Query.equal('consumerNo', consumerNo),
      Query.limit(1),
    ]);
    const existing = clash.documents[0];
    if (existing && existing.userId !== user.$id) {
      await flag(databases, {
        userId: user.$id,
        kind: 'duplicate_consumer_no',
        severity: 'high',
        detail: `consumer ${maskTail(consumerNo)} already claimed`,
        refType: 'electricity',
        refId: existing.$id,
        trustScoreDelta: -15,
      });
      throw new Rejected(
        'consumer_no_taken',
        'That consumer number is already linked to another account.',
      );
    }
    if (existing && existing.userId === user.$id) mine = existing;
  } catch (e) {
    if (e instanceof Rejected) throw e;
    console.error('consumer clash check failed', e.message);
  }

  if (mine) {
    // Already verified: nothing to redo, and a later photo must never
    // downgrade an account that has been approved.
    if (mine.status === 'verified') {
      return {
        account: mine,
        alreadyLinked: true,
        verified: true,
        matchScore: mine.ocrMatchScore ?? 0,
        message: 'This account is already verified.',
      };
    }
    // Pending or rejected: the user was told to submit a clearer photo, so
    // the new one is evaluated. The same document is updated rather than a
    // second one created: the consumer number is unique, so this is also
    // what keeps one account per number. Outside the try above on purpose, so
    // a failed update is reported instead of falling through to a create.
    return reevaluate(databases, user, mine, {
      provider,
      providerCode,
      billFileId,
      ocrExcerpt,
      holderName: str(body.holderName, 128),
      stateName: str(body.stateName, 64),
    });
  }

  const matchScore = ocrMatchScore(consumerNo, ocrExcerpt);
  const verified = matchScore >= VERIFIED_AT;

  const account = await databases.createDocument(
    DB,
    COL.electricityAccounts,
    ID.unique(),
    {
      userId: user.$id,
      consumerNo,
      provider,
      providerCode: providerCode || provider.slice(0, 8).toUpperCase(),
      stateName: str(body.stateName, 64),
      holderName: str(body.holderName, 128),
      billFileId,
      ocrExcerpt: ocrExcerpt.slice(0, 2048),
      ocrMatchScore: matchScore,
      status: verified ? 'verified' : 'pending_review',
      method: 'ocr',
      rejectReason: verified
        ? ''
        : 'Consumer number not clearly visible in the uploaded bill.',
      isPrimary: true,
      submittedAt: nowIso(),
      verifiedAt: verified ? nowIso() : null,
    },
    [Permission.read(Role.user(user.$id))],
  );

  if (verified) {
    await databases.updateDocument(DB, COL.profiles, user.$id, {
      electricityVerified: true,
      primaryConsumerNo: consumerNo,
    });
  }

  await notify(databases, {
    userId: user.$id,
    title: verified ? 'Electricity account verified' : 'Bill under review',
    body: verified
      ? 'You can now redeem credits against your electricity bill.'
      : 'We could not read your consumer number on the bill. Our team will check within 48 hours.',
    type: 'system',
    refId: account.$id,
  });

  return {
    account,
    verified,
    matchScore,
    message: verified
      ? 'Verified from your bill.'
      : 'Queued for manual review. Make sure the consumer number is readable and try a clearer photo.',
  };
}
