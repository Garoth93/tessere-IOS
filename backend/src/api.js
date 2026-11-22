// HTTP API of the Tessere Worker. Storage: D1 (binding DB).
import { buildPkpass, PassError, signingConfigured } from "./pass.js";

export const VERSION = "1.0.0";
const PAGE = 500;
const INVITE_TTL_MS = 48 * 3600 * 1000;
const MAX_PAYLOAD = 400_000;

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function newToken() {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function sha256Hex(text) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time string comparison. */
export function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export function newInviteCode() {
  const r = crypto.getRandomValues(new Uint8Array(8));
  const s = [...r].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

function cleanName(v, fallback) {
  const s = typeof v === "string" ? v.trim().slice(0, 60) : "";
  return s || fallback;
}

async function body(request) {
  try {
    return await request.json();
  } catch {
    throw new HttpError(400, "Richiesta non valida (JSON)");
  }
}

async function authDevice(request, env, required = true) {
  const h = request.headers.get("Authorization") || "";
  const m = /^Bearer\s+(.+)$/.exec(h);
  if (!m) {
    if (required) throw new HttpError(401, "Dispositivo non autorizzato");
    return null;
  }
  const hash = await sha256Hex(m[1].trim());
  const device = await env.DB.prepare("SELECT * FROM devices WHERE token_hash = ?").bind(hash).first();
  if (!device) {
    if (required) throw new HttpError(401, "Dispositivo non riconosciuto: collegalo di nuovo");
    return null;
  }
  await env.DB.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").bind(Date.now(), device.id).run();
  return device;
}

function requireSpace(device) {
  if (!device.space_id) throw new HttpError(403, "Questo dispositivo non fa parte di una famiglia");
  return device.space_id;
}

async function createDevice(env, name, spaceId = null) {
  const id = crypto.randomUUID();
  const token = newToken();
  await env.DB.prepare("INSERT INTO devices (id, token_hash, name, space_id, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(id, await sha256Hex(token), name, spaceId, Date.now()).run();
  return { id, token };
}

// MARK: Handlers

async function health(env) {
  return json({ ok: true, passSigning: signingConfigured(env), version: VERSION });
}

async function registerDevice(request, env) {
  const b = await body(request);
  if (!env.ENROLL_KEY) throw new HttpError(503, "Server non configurato: manca ENROLL_KEY");
  if (!safeEqual(String(b.enrollKey || ""), env.ENROLL_KEY)) throw new HttpError(403, "Chiave di registrazione errata");
  const d = await createDevice(env, cleanName(b.name, "iPhone"));
  return json({ deviceId: d.id, token: d.token });
}

async function createSpace(request, env) {
  const device = await authDevice(request, env);
  const b = await body(request);
  const id = crypto.randomUUID();
  const name = cleanName(b.name, "Famiglia");
  await env.DB.batch([
    env.DB.prepare("INSERT INTO spaces (id, name, owner_device_id, seq, created_at) VALUES (?, ?, ?, 0, ?)").bind(id, name, device.id, Date.now()),
    env.DB.prepare("UPDATE devices SET space_id = ? WHERE id = ?").bind(id, device.id),
  ]);
  return json({ spaceId: id, name });
}

async function createInvite(request, env) {
  const device = await authDevice(request, env);
  const spaceId = requireSpace(device);
  const code = newInviteCode();
  const expires = Date.now() + INVITE_TTL_MS;
  await env.DB.prepare("INSERT INTO invites (code, space_id, created_by, expires_at) VALUES (?, ?, ?, ?)")
    .bind(code, spaceId, device.id, expires).run();
  return json({ code, expiresAt: new Date(expires).toISOString() });
}

async function join(request, env) {
  const b = await body(request);
  const code = String(b.code || "").trim().toUpperCase();
  const invite = await env.DB.prepare("SELECT * FROM invites WHERE code = ?").bind(code).first();
  if (!invite || invite.used_by || invite.expires_at < Date.now()) {
    throw new HttpError(403, "Invito non valido, scaduto o già usato");
  }
  const space = await env.DB.prepare("SELECT * FROM spaces WHERE id = ?").bind(invite.space_id).first();
  if (!space) throw new HttpError(404, "La famiglia non esiste più");
  const name = cleanName(b.name, "iPhone");
  let device = await authDevice(request, env, false);
  let token;
  if (device) {
    await env.DB.prepare("UPDATE devices SET space_id = ?, name = ? WHERE id = ?").bind(space.id, name, device.id).run();
    // Fresh token anyway: the old one may have been shared with the previous family.
    token = newToken();
    await env.DB.prepare("UPDATE devices SET token_hash = ? WHERE id = ?").bind(await sha256Hex(token), device.id).run();
  } else {
    const d = await createDevice(env, name, space.id);
    device = { id: d.id };
    token = d.token;
  }
  await env.DB.prepare("UPDATE invites SET used_by = ?, used_at = ? WHERE code = ?").bind(device.id, Date.now(), code).run();
  return json({ deviceId: device.id, token, spaceId: space.id, spaceName: space.name });
}

async function spaceInfo(request, env) {
  const device = await authDevice(request, env);
  const spaceId = requireSpace(device);
  const space = await env.DB.prepare("SELECT * FROM spaces WHERE id = ?").bind(spaceId).first();
  const { results } = await env.DB.prepare("SELECT id, name, created_at FROM devices WHERE space_id = ? ORDER BY created_at").bind(spaceId).all();
  return json({
    spaceId,
    name: space?.name ?? "Famiglia",
    ownerDeviceId: space?.owner_device_id ?? null,
    members: results.map((m) => ({
      deviceId: m.id,
      name: m.name,
      joinedAt: new Date(m.created_at).toISOString(),
      isYou: m.id === device.id,
      isOwner: m.id === space?.owner_device_id,
    })),
  });
}

async function removeMember(request, env, memberId) {
  const device = await authDevice(request, env);
  const spaceId = requireSpace(device);
  const space = await env.DB.prepare("SELECT * FROM spaces WHERE id = ?").bind(spaceId).first();
  const self = memberId === device.id;
  if (!self && space?.owner_device_id !== device.id) throw new HttpError(403, "Solo chi ha creato la famiglia può rimuovere un membro");
  const target = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND space_id = ?").bind(memberId, spaceId).first();
  if (!target) throw new HttpError(404, "Membro non trovato");
  await env.DB.prepare("UPDATE devices SET space_id = NULL WHERE id = ?").bind(memberId).run();
  // The owner leaving hands the family to the oldest remaining member.
  if (space?.owner_device_id === memberId) {
    const next = await env.DB.prepare("SELECT id FROM devices WHERE space_id = ? ORDER BY created_at LIMIT 1").bind(spaceId).first();
    if (next) await env.DB.prepare("UPDATE spaces SET owner_device_id = ? WHERE id = ?").bind(next.id, spaceId).run();
  }
  return json({ ok: true });
}

function validRecord(r) {
  return r && typeof r.id === "string" && r.id.length > 0 && r.id.length <= 64 &&
    Number.isSafeInteger(r.updatedAt) && r.updatedAt >= 0 &&
    typeof r.deleted === "boolean" &&
    (r.deleted || (typeof r.payload === "string" && r.payload.length <= MAX_PAYLOAD));
}

function out(row) {
  return { id: row.id, seq: row.seq, updatedAt: row.updated_at, deleted: !!row.deleted, payload: row.deleted ? null : row.payload };
}

/** Push + pull in one call (last writer wins on `updatedAt`). */
async function sync(request, env) {
  const device = await authDevice(request, env);
  const spaceId = requireSpace(device);
  const b = await body(request);
  const since = Number.isSafeInteger(b.since) && b.since >= 0 ? b.since : 0;
  const changes = Array.isArray(b.changes) ? b.changes.slice(0, 500) : [];
  const applied = [];
  const rejected = [];

  for (const r of changes) {
    if (!validRecord(r)) continue;
    const existing = await env.DB.prepare("SELECT updated_at FROM records WHERE space_id = ? AND id = ?").bind(spaceId, r.id).first();
    if (existing && existing.updated_at > r.updatedAt) {
      rejected.push(r.id);
      continue;
    }
    if (existing && existing.updated_at === r.updatedAt) {
      applied.push(r.id); // retry of the same version
      continue;
    }
    const seqRow = await env.DB.prepare("UPDATE spaces SET seq = seq + 1 WHERE id = ? RETURNING seq").bind(spaceId).first();
    await env.DB.prepare(
      `INSERT INTO records (space_id, id, seq, updated_at, deleted, payload, device_id) VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (space_id, id) DO UPDATE SET seq = excluded.seq, updated_at = excluded.updated_at,
         deleted = excluded.deleted, payload = excluded.payload, device_id = excluded.device_id
       WHERE excluded.updated_at > records.updated_at`
    ).bind(spaceId, r.id, seqRow.seq, r.updatedAt, r.deleted ? 1 : 0, r.deleted ? null : r.payload, device.id).run();
    applied.push(r.id);
  }

  const { results } = await env.DB.prepare(
    "SELECT id, seq, updated_at, deleted, payload FROM records WHERE space_id = ? AND seq > ? ORDER BY seq LIMIT ?"
  ).bind(spaceId, since, PAGE + 1).all();
  const more = results.length > PAGE;
  const page = results.slice(0, PAGE);
  const space = await env.DB.prepare("SELECT seq FROM spaces WHERE id = ?").bind(spaceId).first();
  const cursor = more ? page[page.length - 1].seq : Math.max(since, space?.seq ?? 0);
  const outChanges = page.map(out);

  // Newer server versions of refused records, even if older than `since`.
  const seen = new Set(outChanges.map((c) => c.id));
  for (const id of rejected) {
    if (seen.has(id)) continue;
    const row = await env.DB.prepare("SELECT id, seq, updated_at, deleted, payload FROM records WHERE space_id = ? AND id = ?").bind(spaceId, id).first();
    if (row) outChanges.push(out(row));
  }
  return json({ cursor, changes: outChanges, applied, rejected, more });
}

async function pass(request, env) {
  await authDevice(request, env);
  const b = await body(request);
  try {
    const bytes = await buildPkpass(b, env);
    return new Response(bytes, {
      headers: {
        "Content-Type": "application/vnd.apple.pkpass",
        "Content-Disposition": `attachment; filename="tessera.pkpass"`,
        "Cache-Control": "no-store",
      },
    });
  } catch (e) {
    if (e instanceof PassError) throw new HttpError(e.status, e.message);
    throw new HttpError(500, `Firma del pass non riuscita: ${e.message}`);
  }
}

// MARK: Router

export async function handle(request, env) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "");
  const m = request.method;
  try {
    if (m === "GET" && (path === "" || path === "/v1/health")) return await health(env);
    if (m === "POST" && path === "/v1/devices") return await registerDevice(request, env);
    if (m === "POST" && path === "/v1/spaces") return await createSpace(request, env);
    if (m === "POST" && path === "/v1/spaces/invite") return await createInvite(request, env);
    if (m === "POST" && path === "/v1/join") return await join(request, env);
    if (m === "GET" && path === "/v1/space") return await spaceInfo(request, env);
    const del = /^\/v1\/space\/members\/([A-Za-z0-9-]{1,64})$/.exec(path);
    if (m === "DELETE" && del) return await removeMember(request, env, del[1]);
    if (m === "POST" && path === "/v1/sync") return await sync(request, env);
    if (m === "POST" && path === "/v1/pass") return await pass(request, env);
    return json({ error: "Non trovato" }, 404);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: "Errore interno del server" }, 500);
  }
}
