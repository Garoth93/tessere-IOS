// Signs a pass with a throw-away self-signed certificate and checks it with
// openssl: manifest hashes, detached PKCS#7 signature, archive layout.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { buildPkpass, buildPassJSON, PassError } from "../src/pass.js";
import { handle } from "../src/api.js";
import { makeD1 } from "./d1shim.js";

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

function certs(dir) {
  const run = (args) => execFileSync("openssl", args, { cwd: dir, stdio: "pipe" });
  run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2", "-subj", "/CN=WWDR TEST"]);
  run(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "pass.key", "-out", "pass.csr", "-subj", "/CN=Pass Type ID TEST"]);
  run(["x509", "-req", "-in", "pass.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "pass.pem", "-days", "2"]);
  return {
    PASS_TYPE_ID: "pass.com.example.tessere.test",
    TEAM_ID: "TEAMTEST01",
    PASS_CERT_PEM: readFileSync(join(dir, "pass.pem"), "utf8"),
    PASS_KEY_PEM: readFileSync(join(dir, "pass.key"), "utf8"),
    WWDR_CERT_PEM: readFileSync(join(dir, "ca.pem"), "utf8"),
  };
}

const request = {
  serialNumber: "11111111-2222-3333-4444-555555555555",
  organizationName: "Negozio TEST",
  description: "Tessera Negozio TEST",
  logoText: "Negozio TEST",
  kindLabel: "TESSERA",
  message: "4006381333931",
  format: "PKBarcodeFormatCode128",
  altText: "4006381333931",
  backgroundColor: "rgb(226, 35, 26)",
  foregroundColor: "rgb(255, 255, 255)",
  labelColor: "rgb(210, 210, 210)",
  note: "Sconto 10%",
  expirationDate: "2030-01-31T23:59:59Z",
  locations: [{ latitude: 45.46, longitude: 9.19, relevantText: "Sei vicino" }, { latitude: 999, longitude: 0 }],
  iconPNG: PNG,
  logoPNG: PNG,
};

test("pass.json fields", () => {
  const env = { PASS_TYPE_ID: "p", TEAM_ID: "t" };
  const p = buildPassJSON(request, env);
  assert.equal(p.passTypeIdentifier, "p");
  assert.equal(p.barcodes[0].format, "PKBarcodeFormatCode128");
  assert.equal(p.locations.length, 1);
  assert.equal(p.generic.primaryFields[0].value, "Negozio TEST");
  assert.ok(p.generic.auxiliaryFields.some((f) => f.key === "note"));
  assert.throws(() => buildPassJSON({ ...request, format: "PKBarcodeFormatEAN13" }, env), PassError);
  assert.throws(() => buildPassJSON({ ...request, backgroundColor: "red" }, env), PassError);
});

test("signed pkpass verifies with openssl", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tessere-pass-"));
  const env = certs(dir);
  const bytes = await buildPkpass(request, env);
  writeFileSync(join(dir, "t.pkpass"), bytes);
  execFileSync("python3", ["-c", `import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])`, join(dir, "t.pkpass"), join(dir, "x")]);
  const x = join(dir, "x");
  for (const f of ["pass.json", "manifest.json", "signature", "icon.png", "icon@2x.png", "logo@3x.png"]) {
    assert.ok(existsSync(join(x, f)), f);
  }
  const manifest = JSON.parse(readFileSync(join(x, "manifest.json"), "utf8"));
  for (const [name, hash] of Object.entries(manifest)) {
    assert.equal(createHash("sha1").update(readFileSync(join(x, name))).digest("hex"), hash, name);
  }
  assert.ok(!("signature" in manifest) && !("manifest.json" in manifest));
  // Detached signature over manifest.json, chained to the "WWDR" test CA.
  execFileSync("openssl", ["smime", "-verify", "-binary", "-inform", "DER", "-in", join(x, "signature"),
    "-content", join(x, "manifest.json"), "-CAfile", join(dir, "ca.pem"), "-purpose", "any", "-out", "/dev/null"], { stdio: "pipe" });
  const certsOut = execFileSync("openssl", ["pkcs7", "-inform", "DER", "-in", join(x, "signature"), "-print_certs", "-noout"]).toString();
  assert.match(certsOut, /Pass Type ID TEST/);
  assert.match(certsOut, /WWDR TEST/);
  const pass = JSON.parse(readFileSync(join(x, "pass.json"), "utf8"));
  assert.equal(pass.teamIdentifier, "TEAMTEST01");
});

test("POST /v1/pass returns a pkpass", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tessere-pass-"));
  const e = { DB: makeD1(), ENROLL_KEY: "k", ...certs(dir) };
  const reg = await handle(new Request("https://w.test/v1/devices", { method: "POST", body: JSON.stringify({ name: "A", enrollKey: "k" }) }), e);
  const { token } = await reg.json();
  const r = await handle(new Request("https://w.test/v1/pass", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(request) }), e);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "application/vnd.apple.pkpass");
  const b = new Uint8Array(await r.arrayBuffer());
  assert.equal(b[0], 0x50); assert.equal(b[1], 0x4b);
  const health = await (await handle(new Request("https://w.test/v1/health"), e)).json();
  assert.equal(health.passSigning, true);
});
