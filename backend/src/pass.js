// Builds and signs an Apple Wallet generic pass (.pkpass).
import forge from "node-forge";
import { zip } from "./zip.js";

const FORMATS = new Set(["PKBarcodeFormatQR", "PKBarcodeFormatPDF417", "PKBarcodeFormatAztec", "PKBarcodeFormatCode128"]);
const RGB = /^rgb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)$/;

export class PassError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

export function signingConfigured(env) {
  return Boolean(env.PASS_TYPE_ID && env.TEAM_ID && env.WWDR_CERT_PEM &&
    ((env.PASS_CERT_PEM && env.PASS_KEY_PEM) || env.PASS_P12_BASE64));
}

function str(v, max, name, required = false) {
  if (v === undefined || v === null || v === "") {
    if (required) throw new PassError(`Campo mancante: ${name}`);
    return undefined;
  }
  if (typeof v !== "string") throw new PassError(`Campo non valido: ${name}`);
  return v.slice(0, max);
}

function png(b64, name, maxBytes, required = false) {
  if (!b64) {
    if (required) throw new PassError(`Immagine mancante: ${name}`);
    return undefined;
  }
  let bytes;
  try {
    bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  } catch {
    throw new PassError(`Immagine non valida: ${name}`);
  }
  if (bytes.length > maxBytes) throw new PassError(`Immagine troppo grande: ${name}`);
  if (bytes.length < 8 || bytes[0] !== 0x89 || bytes[1] !== 0x50 || bytes[2] !== 0x4e || bytes[3] !== 0x47) {
    throw new PassError(`L'immagine ${name} non è un PNG`);
  }
  return bytes;
}

/** pass.json content from the app request (see PassRequest in TessereCore). */
export function buildPassJSON(req, env) {
  const format = str(req.format, 64, "format", true);
  if (!FORMATS.has(format)) throw new PassError("Formato di codice non supportato da Wallet");
  for (const k of ["backgroundColor", "foregroundColor", "labelColor"]) {
    if (!RGB.test(req[k] || "")) throw new PassError(`Colore non valido: ${k}`);
  }
  const serial = str(req.serialNumber, 64, "serialNumber", true);
  const message = str(req.message, 2000, "message", true);
  const org = str(req.organizationName, 64, "organizationName", true);
  const kind = str(req.kindLabel, 30, "kindLabel") || "TESSERA";
  const barcode = { message, format, messageEncoding: "iso-8859-1" };
  const alt = str(req.altText, 80, "altText");
  if (alt) barcode.altText = alt;

  const pass = {
    formatVersion: 1,
    passTypeIdentifier: env.PASS_TYPE_ID,
    teamIdentifier: env.TEAM_ID,
    serialNumber: serial,
    organizationName: org,
    description: str(req.description, 120, "description") || org,
    foregroundColor: req.foregroundColor,
    backgroundColor: req.backgroundColor,
    labelColor: req.labelColor,
    barcodes: [barcode],
    barcode,
    sharingProhibited: false,
    generic: {
      primaryFields: [{ key: "store", label: kind, value: org }],
      secondaryFields: [],
      auxiliaryFields: [],
      backFields: [{ key: "number", label: "Numero", value: alt || message }],
    },
  };
  const logoText = str(req.logoText, 40, "logoText");
  if (logoText) pass.logoText = logoText;
  const holder = str(req.cardholder, 60, "cardholder");
  if (holder) pass.generic.secondaryFields.push({ key: "holder", label: "TITOLARE", value: holder });
  const note = str(req.note, 300, "note");
  if (note) {
    pass.generic.auxiliaryFields.push({ key: "note", label: "NOTA", value: note });
    pass.generic.backFields.push({ key: "noteBack", label: "Nota", value: note });
  }
  const exp = str(req.expirationDate, 40, "expirationDate");
  if (exp) {
    if (Number.isNaN(Date.parse(exp))) throw new PassError("Data di scadenza non valida");
    pass.expirationDate = exp;
    pass.generic.auxiliaryFields.push({ key: "expiry", label: "SCADENZA", value: exp, dateStyle: "PKDateStyleMedium", timeStyle: "PKDateStyleNone" });
  }
  if (Array.isArray(req.locations) && req.locations.length) {
    pass.locations = req.locations.slice(0, 10).filter((l) =>
      Number.isFinite(l?.latitude) && Number.isFinite(l?.longitude) &&
      Math.abs(l.latitude) <= 90 && Math.abs(l.longitude) <= 180
    ).map((l) => {
      const out = { latitude: l.latitude, longitude: l.longitude };
      const t = str(l.relevantText, 120, "relevantText");
      if (t) out.relevantText = t;
      return out;
    });
    if (!pass.locations.length) delete pass.locations;
  }
  return pass;
}

async function sha1Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-1", bytes));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function toBinaryString(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return s;
}

function fromBinaryString(s) {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
}

/** Signer certificate + key from PEM secrets or from a base64 .p12. */
export function loadSigner(env) {
  if (env.PASS_CERT_PEM && env.PASS_KEY_PEM) {
    const cert = forge.pki.certificateFromPem(env.PASS_CERT_PEM);
    const key = env.PASS_KEY_PASSWORD
      ? forge.pki.decryptRsaPrivateKey(env.PASS_KEY_PEM, env.PASS_KEY_PASSWORD)
      : forge.pki.privateKeyFromPem(env.PASS_KEY_PEM);
    if (!key) throw new PassError("Chiave privata del certificato non leggibile (password?)", 500);
    return { cert, key };
  }
  const der = forge.util.decode64(env.PASS_P12_BASE64);
  const p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(der), env.PASS_P12_PASSWORD || "");
  const certBag = p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag]?.[0];
  const keyBag = p12.getBags({ bagType: forge.pki.oids.pkcs8ShroudedKeyBag })[forge.pki.oids.pkcs8ShroudedKeyBag]?.[0];
  if (!certBag?.cert || !keyBag?.key) throw new PassError("Certificato .p12 non leggibile", 500);
  return { cert: certBag.cert, key: keyBag.key };
}

/** Detached PKCS#7 (DER) signature of the manifest. */
export function signManifest(manifestBytes, env, now = new Date()) {
  const { cert, key } = loadSigner(env);
  const wwdr = forge.pki.certificateFromPem(env.WWDR_CERT_PEM);
  const p7 = forge.pkcs7.createSignedData();
  p7.content = forge.util.createBuffer(toBinaryString(manifestBytes));
  p7.addCertificate(cert);
  p7.addCertificate(wwdr);
  p7.addSigner({
    key,
    certificate: cert,
    digestAlgorithm: forge.pki.oids.sha256,
    authenticatedAttributes: [
      { type: forge.pki.oids.contentType, value: forge.pki.oids.data },
      { type: forge.pki.oids.messageDigest },
      { type: forge.pki.oids.signingTime, value: now },
    ],
  });
  p7.sign({ detached: true });
  return fromBinaryString(forge.asn1.toDer(p7.toAsn1()).getBytes());
}

/** Full .pkpass archive. */
export async function buildPkpass(req, env) {
  if (!signingConfigured(env)) {
    throw new PassError("Il server non ha ancora il certificato Wallet (vedi README › Wallet).", 501);
  }
  const passJSON = buildPassJSON(req, env);
  const icon = png(req.iconPNG, "icon", 200_000, true);
  const logo = png(req.logoPNG, "logo", 400_000);
  const strip = png(req.stripPNG, "strip", 600_000);
  const enc = new TextEncoder();
  const files = [{ name: "pass.json", data: enc.encode(JSON.stringify(passJSON)) }];
  for (const n of ["icon.png", "icon@2x.png", "icon@3x.png"]) files.push({ name: n, data: icon });
  if (logo) for (const n of ["logo.png", "logo@2x.png", "logo@3x.png"]) files.push({ name: n, data: logo });
  if (strip) for (const n of ["strip.png", "strip@2x.png", "strip@3x.png"]) files.push({ name: n, data: strip });
  const manifest = {};
  for (const f of files) manifest[f.name] = await sha1Hex(f.data);
  const manifestBytes = enc.encode(JSON.stringify(manifest));
  files.push({ name: "manifest.json", data: manifestBytes });
  files.push({ name: "signature", data: signManifest(manifestBytes, env) });
  return zip(files);
}
