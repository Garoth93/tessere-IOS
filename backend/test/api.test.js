import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../src/api.js";
import { makeD1 } from "./d1shim.js";

function env(extra = {}) {
  return { DB: makeD1(), ENROLL_KEY: "enroll-TEST", PASS_TYPE_ID: "", TEAM_ID: "", ...extra };
}

async function call(e, method, path, body, token) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await handle(new Request(`https://w.test${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined }), e);
  const type = res.headers.get("Content-Type") || "";
  return { status: res.status, body: type.includes("json") ? await res.json() : new Uint8Array(await res.arrayBuffer()), type };
}

test("health", async () => {
  const r = await call(env(), "GET", "/v1/health");
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.passSigning, false);
});

test("registration needs the enroll key", async () => {
  const e = env();
  assert.equal((await call(e, "POST", "/v1/devices", { name: "A", enrollKey: "wrong" })).status, 403);
  const ok = await call(e, "POST", "/v1/devices", { name: "A", enrollKey: "enroll-TEST" });
  assert.equal(ok.status, 200);
  assert.ok(ok.body.token.length > 20);
  assert.equal((await call(e, "POST", "/v1/sync", { since: 0, changes: [] }, "nope")).status, 401);
  // Registered but not in a family.
  assert.equal((await call(e, "POST", "/v1/sync", { since: 0, changes: [] }, ok.body.token)).status, 403);
});

test("family: create, invite, join, sync with LWW, members, leave", async () => {
  const e = env();
  const a = (await call(e, "POST", "/v1/devices", { name: "A TEST", enrollKey: "enroll-TEST" })).body;
  const space = await call(e, "POST", "/v1/spaces", { name: "Famiglia TEST" }, a.token);
  assert.equal(space.status, 200);

  const inv = await call(e, "POST", "/v1/spaces/invite", null, a.token);
  assert.match(inv.body.code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  const b = await call(e, "POST", "/v1/join", { code: inv.body.code, name: "B TEST" });
  assert.equal(b.status, 200);
  assert.equal(b.body.spaceId, space.body.spaceId);
  // Single use.
  assert.equal((await call(e, "POST", "/v1/join", { code: inv.body.code, name: "C" })).status, 403);

  // A pushes a card.
  const push = await call(e, "POST", "/v1/sync", { since: 0, changes: [{ id: "c1", updatedAt: 1000, deleted: false, payload: "enc1" }] }, a.token);
  assert.deepEqual(push.body.applied, ["c1"]);
  assert.equal(push.body.cursor, 1);

  // B pulls it.
  const pull = await call(e, "POST", "/v1/sync", { since: 0, changes: [] }, b.body.token);
  assert.equal(pull.body.changes.length, 1);
  assert.equal(pull.body.changes[0].payload, "enc1");
  assert.equal(pull.body.cursor, 1);

  // B sends an older version: refused, server version returned.
  const old = await call(e, "POST", "/v1/sync", { since: 1, changes: [{ id: "c1", updatedAt: 900, deleted: false, payload: "old" }] }, b.body.token);
  assert.deepEqual(old.body.rejected, ["c1"]);
  assert.equal(old.body.changes[0].payload, "enc1");

  // Same version again (retry) is accepted without a new seq.
  const retry = await call(e, "POST", "/v1/sync", { since: 1, changes: [{ id: "c1", updatedAt: 1000, deleted: false, payload: "enc1" }] }, a.token);
  assert.deepEqual(retry.body.applied, ["c1"]);
  assert.equal(retry.body.cursor, 1);

  // B deletes it (newer): A receives the tombstone.
  await call(e, "POST", "/v1/sync", { since: 1, changes: [{ id: "c1", updatedAt: 2000, deleted: true, payload: null }] }, b.body.token);
  const del = await call(e, "POST", "/v1/sync", { since: 1, changes: [] }, a.token);
  assert.equal(del.body.changes.length, 1);
  assert.equal(del.body.changes[0].deleted, true);
  assert.equal(del.body.changes[0].payload, null);

  // Invalid records are ignored.
  const bad = await call(e, "POST", "/v1/sync", { since: 0, changes: [{ id: "", updatedAt: 1 }, { id: "x", updatedAt: -1, deleted: false, payload: "p" }] }, a.token);
  assert.deepEqual(bad.body.applied, []);

  // Members and permissions.
  const info = await call(e, "GET", "/v1/space", null, b.body.token);
  assert.equal(info.body.members.length, 2);
  assert.equal(info.body.members.find((m) => m.isYou).name, "B TEST");
  assert.equal((await call(e, "DELETE", `/v1/space/members/${a.deviceId}`, null, b.body.token)).status, 403);
  assert.equal((await call(e, "DELETE", `/v1/space/members/${b.body.deviceId}`, null, a.token)).status, 200);
  assert.equal((await call(e, "POST", "/v1/sync", { since: 0, changes: [] }, b.body.token)).status, 403);

  // Owner leaving hands over ownership.
  const inv2 = await call(e, "POST", "/v1/spaces/invite", null, a.token);
  const c = await call(e, "POST", "/v1/join", { code: inv2.body.code, name: "C TEST" });
  await call(e, "DELETE", `/v1/space/members/${a.deviceId}`, null, a.token);
  const info2 = await call(e, "GET", "/v1/space", null, c.body.token);
  assert.equal(info2.body.ownerDeviceId, c.body.deviceId);
});

test("pagination with more", async () => {
  const e = env();
  const a = (await call(e, "POST", "/v1/devices", { name: "A", enrollKey: "enroll-TEST" })).body;
  await call(e, "POST", "/v1/spaces", { name: "F" }, a.token);
  const changes = Array.from({ length: 500 }, (_, i) => ({ id: `c${i}`, updatedAt: 1 + i, deleted: false, payload: "p" }));
  await call(e, "POST", "/v1/sync", { since: 0, changes }, a.token);
  await call(e, "POST", "/v1/sync", { since: 0, changes: [{ id: "z", updatedAt: 5, deleted: false, payload: "p" }] }, a.token);
  const p1 = await call(e, "POST", "/v1/sync", { since: 0, changes: [] }, a.token);
  assert.equal(p1.body.more, true);
  assert.equal(p1.body.changes.length, 500);
  const p2 = await call(e, "POST", "/v1/sync", { since: p1.body.cursor, changes: [] }, a.token);
  assert.equal(p2.body.more, false);
  assert.equal(p2.body.changes.length, 1);
  assert.equal(p2.body.cursor, 501);
});

test("expired invite refused", async () => {
  const e = env();
  const a = (await call(e, "POST", "/v1/devices", { name: "A", enrollKey: "enroll-TEST" })).body;
  await call(e, "POST", "/v1/spaces", { name: "F" }, a.token);
  await e.DB.prepare("INSERT INTO invites (code, space_id, created_by, expires_at) VALUES ('AAAA-BBBB', 'x', 'y', 1)").run();
  assert.equal((await call(e, "POST", "/v1/join", { code: "aaaa-bbbb", name: "B" })).status, 403);
});

test("pass without certificate: 501", async () => {
  const e = env();
  const a = (await call(e, "POST", "/v1/devices", { name: "A", enrollKey: "enroll-TEST" })).body;
  const r = await call(e, "POST", "/v1/pass", { format: "PKBarcodeFormatQR" }, a.token);
  assert.equal(r.status, 501);
});
