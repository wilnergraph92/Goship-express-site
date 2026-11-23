const MAX_BODY_BYTES = 20_000;
const MAX_EVENTS_PER_REQUEST = 1_000;
const textEncoder = new TextEncoder();
import { createSupabaseRpcClient, SupabaseRpcFailure } from "./supabase-rpc.mjs";

export class HttpFailure extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const cleanString = value => typeof value === "string" ? value.trim() : "";

function envValue(env, name) {
  if (typeof env === "function") return env(name) ?? "";
  return env?.[name] ?? "";
}

export function safeEqual(left, right) {
  const a = textEncoder.encode(String(left ?? ""));
  const b = textEncoder.encode(String(right ?? ""));
  let difference = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i += 1) difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return difference === 0;
}

async function hmacBytes(secretBytes, message) {
  const key = await crypto.subtle.importKey(
    "raw", secretBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
}

export async function hmacSha256Hex(secret, message) {
  const signature = await hmacBytes(textEncoder.encode(secret), textEncoder.encode(message));
  return [...signature].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(message) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", textEncoder.encode(message)));
  return [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export async function verifyMetaSignature(rawBody, header, appSecret) {
  const match = /^sha256=([0-9a-f]{64})$/i.exec(header ?? "");
  if (!match || !appSecret) return false;
  const expected = await hmacSha256Hex(appSecret, rawBody);
  return safeEqual(expected.toLowerCase(), match[1].toLowerCase());
}

function fromBase64(value) {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Error("invalid base64");
  const binary = atob(value);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function bytesToBase64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function safeBytesEqual(left, right) {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i += 1) difference |= (left[i] ?? 0) ^ (right[i] ?? 0);
  return difference === 0;
}

export async function verifyResendSignature(headers, rawBody, webhookSecret, now = Date.now()) {
  if (!webhookSecret?.startsWith("whsec_")) return false;
  const id = headers.get("svix-id");
  const timestamp = headers.get("svix-timestamp");
  const signatureHeader = headers.get("svix-signature");
  if (!id || !/^[A-Za-z0-9_:-]{1,200}$/.test(id) || !timestamp || !signatureHeader) return false;
  if (!/^\d{1,12}$/.test(timestamp)) return false;

  const timestampMs = Number(timestamp) * 1_000;
  if (!Number.isSafeInteger(timestampMs) || Math.abs(now - timestampMs) > 300_000) return false;

  let keyBytes;
  try {
    keyBytes = fromBase64(webhookSecret.slice("whsec_".length));
  } catch {
    return false;
  }
  const signedContent = textEncoder.encode(`${id}.${timestamp}.${rawBody}`);
  const expected = bytesToBase64(await hmacBytes(keyBytes, signedContent));
  const candidates = signatureHeader.split(/\s+/).flatMap(part => {
    const match = /^v1,([A-Za-z0-9+/]+={0,2})$/.exec(part);
    if (!match) return [];
    try { return [fromBase64(match[1])]; } catch { return []; }
  });
  return candidates.some(candidate => safeBytesEqual(expectedBytes(expected), candidate));
}

function expectedBytes(base64) {
  return fromBase64(base64);
}

export function verifyBrevoBearer(headers, configuredToken) {
  if (!configuredToken) return false;
  const header = headers.get("authorization") ?? "";
  const match = /^Bearer (\S{1,2048})$/i.exec(header);
  return Boolean(match && safeEqual(match[1], configuredToken));
}

export async function readBoundedBody(request, maxBytes = MAX_BODY_BYTES) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) throw new HttpFailure(413, "BODY_TOO_LARGE");
  if (!request.body) return "";

  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new HttpFailure(413, "BODY_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    throw new HttpFailure(400, "BODY_ENCODING_INVALID");
  }
}

function isoFromProviderTime(value, seconds = true) {
  if (typeof value === "number" || (typeof value === "string" && /^\d{1,13}$/.test(value))) {
    const numeric = Number(value);
    const millis = seconds && numeric < 100_000_000_000 ? numeric * 1_000 : numeric;
    if (!Number.isFinite(millis)) return null;
    try { return new Date(millis).toISOString(); } catch { return null; }
  }
  if (typeof value === "string" && value.length <= 64) {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return new Date(parsed).toISOString();
  }
  return null;
}

function normalizedEvent({ provider, id, type, messageId = null, code = null, occurredAt = null,
  phone = null, text = null, button = null }) {
  const event = {
    id: cleanString(id),
    type,
    message_id: messageId === null ? null : cleanString(String(messageId)),
    reference: null,
    code,
    survenu_le: occurredAt
  };
  if (phone !== null) event.telephone = phone;
  if (text !== null) event.texte = text;
  if (button !== null) event.bouton = button;
  if (!event.id || event.id.length > 200 || (event.message_id && event.message_id.length > 200)) {
    throw new HttpFailure(400, "EVENT_IDENTIFIER_INVALID");
  }
  return { provider, event };
}

const META_STATUS = new Map([
  ["sent", "sent"], ["delivered", "delivered"], ["read", "read"], ["failed", "failed"]
]);

export function normalizeMeta(payload) {
  if (!object(payload) || payload.object !== "whatsapp_business_account" || !Array.isArray(payload.entry)) {
    throw new HttpFailure(400, "META_PAYLOAD_INVALID");
  }
  const output = [];
  for (const entry of payload.entry) {
    if (!object(entry) || !Array.isArray(entry.changes)) continue;
    for (const change of entry.changes) {
      const value = change?.value;
      if (!object(value)) continue;
      if (Array.isArray(value.statuses)) {
        for (const status of value.statuses) {
          if (!object(status)) continue;
          const type = META_STATUS.get(cleanString(status.status).toLowerCase());
          const messageId = cleanString(status.id);
          if (!type || !messageId) continue;
          const occurredAt = isoFromProviderTime(status.timestamp);
          if (!occurredAt) throw new HttpFailure(400, "META_STATUS_TIMESTAMP_INVALID");
          const stamp = cleanString(status.timestamp) || "unknown";
          const rawCode = status.errors?.[0]?.code;
          const code = rawCode === undefined || rawCode === null ? null : `META_${String(rawCode).replace(/[^0-9A-Za-z_-]/g, "").slice(0, 50)}`;
          output.push(normalizedEvent({
            provider: "meta",
            id: `meta:${messageId}:${type}:${stamp}`,
            type,
            messageId,
            code,
            occurredAt
          }));
        }
      }
      if (Array.isArray(value.messages)) {
        for (const message of value.messages) {
          if (!object(message)) continue;
          const id = cleanString(message.id);
          const phone = cleanString(message.from);
          if (!id || !/^\+?[0-9]{5,20}$/.test(phone)) throw new HttpFailure(400, "META_INBOUND_INVALID");
          let text = null;
          let button = null;
          if (object(message.text) && typeof message.text.body === "string") text = message.text.body.slice(0, 10_000);
          if (object(message.button) && typeof message.button.text === "string") button = message.button.text.slice(0, 1_000);
          if (object(message.interactive?.button_reply) && typeof message.interactive.button_reply.title === "string") {
            button = message.interactive.button_reply.title.slice(0, 1_000);
          } else if (object(message.interactive?.list_reply) && typeof message.interactive.list_reply.title === "string") {
            button = message.interactive.list_reply.title.slice(0, 1_000);
          }
          output.push(normalizedEvent({
            provider: "meta", id, type: "inbound", phone, text, button,
            occurredAt: isoFromProviderTime(message.timestamp)
          }));
        }
      }
      if (output.length > MAX_EVENTS_PER_REQUEST) throw new HttpFailure(413, "TOO_MANY_EVENTS");
    }
  }
  return output;
}

const BREVO_EVENTS = new Map([
  ["request", "sent"], ["sent", "sent"], ["delivered", "delivered"],
  ["hardbounce", "hard_bounce"], ["hard_bounce", "hard_bounce"], ["invalid", "hard_bounce"],
  ["softbounce", "soft_bounce"], ["soft_bounce", "soft_bounce"], ["deferred", "soft_bounce"],
  ["blocked", "blocked"], ["spam", "complaint"], ["unsubscribed", "unsubscribe"]
]);

export async function normalizeBrevo(payload) {
  const items = Array.isArray(payload) ? payload : [payload];
  if (items.some(item => !object(item))) throw new HttpFailure(400, "BREVO_PAYLOAD_INVALID");
  const output = [];
  for (const item of items) {
    const sourceType = cleanString(item.event).toLowerCase();
    const type = BREVO_EVENTS.get(sourceType);
    if (!type) continue;
    const messageId = cleanString(item["message-id"] ?? item.messageId);
    if (!messageId) throw new HttpFailure(503, "BREVO_EVENT_CORRELATION_UNAVAILABLE");
    const eventTime = item.ts_event ?? item.ts;
    const occurredAt = isoFromProviderTime(eventTime);
    if (!occurredAt) throw new HttpFailure(400, "BREVO_EVENT_TIMESTAMP_INVALID");
    const stamp = eventTime === undefined || eventTime === null ? "unknown" : String(eventTime);
    const eventKey = await sha256Hex(`${messageId}\n${sourceType}\n${stamp}`);
    output.push(normalizedEvent({
      provider: "brevo",
      id: `brevo:${eventKey}`,
      type,
      messageId,
      code: `BREVO_${sourceType.toUpperCase().replace(/[^A-Z0-9_]/g, "_").slice(0, 50)}`,
      occurredAt
    }));
  }
  if (output.length > MAX_EVENTS_PER_REQUEST) throw new HttpFailure(413, "TOO_MANY_EVENTS");
  return output;
}

const RESEND_EVENTS = new Map([
  ["email.sent", "sent"], ["email.delivered", "delivered"], ["email.bounced", "hard_bounce"],
  ["email.complained", "complaint"], ["email.failed", "failed"], ["email.suppressed", "blocked"]
]);

export function normalizeResend(payload, headers) {
  if (!object(payload) || !object(payload.data)) throw new HttpFailure(400, "RESEND_PAYLOAD_INVALID");
  if (payload.type === "contact.updated" && payload.data.unsubscribed === true) {
    // Pas de correspondance approuvée entre un contact Resend et le compte/canal GoShip.
    throw new HttpFailure(503, "RESEND_CONTACT_CORRELATION_UNAVAILABLE");
  }
  const type = RESEND_EVENTS.get(cleanString(payload.type));
  if (!type) return [];
  const messageId = cleanString(payload.data.email_id);
  const svixId = cleanString(headers.get("svix-id"));
  if (!messageId || !svixId) throw new HttpFailure(400, "RESEND_EVENT_IDENTIFIER_INVALID");
  const occurredAt = isoFromProviderTime(payload.created_at ?? payload.data.created_at, false);
  if (!occurredAt) throw new HttpFailure(400, "RESEND_EVENT_TIMESTAMP_INVALID");
  return [normalizedEvent({
    provider: "resend",
    id: `resend:${svixId}`,
    type,
    messageId,
    code: `RESEND_${type.toUpperCase()}`,
    occurredAt
  })];
}

function jsonResponse(status, value) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}

function textResponse(status, text) {
  return new Response(text, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" }
  });
}

function parseJson(raw) {
  try { return JSON.parse(raw); } catch { throw new HttpFailure(400, "JSON_INVALID"); }
}

async function persistWithSupabase({ env, fetchImpl, provider, event, now }) {
  const hmacSecret = envValue(env, "COMMUNICATION_WEBHOOK_HMAC_SECRET");
  if (!hmacSecret) {
    throw new HttpFailure(503, "PERSISTENCE_NOT_CONFIGURED");
  }
  const transactionTypes = new Set(["sent", "delivered", "read", "failed", "hard_bounce", "blocked"]);
  const rpcName = transactionTypes.has(event.type)
    ? "communication_edge_webhook_recevoir_statut_transactionnel"
    : "communication_edge_webhook_recevoir_evenement";
  const charge = JSON.stringify(event);
  if (textEncoder.encode(charge).byteLength > MAX_BODY_BYTES) throw new HttpFailure(413, "NORMALIZED_EVENT_TOO_LARGE");
  const signature = await hmacSha256Hex(hmacSecret, `${provider}:${charge}`);
  let result;
  try {
    const callRpc = createSupabaseRpcClient({
      env, fetchImpl, expectedRole: "communication_webhook", now
    });
    result = await callRpc(rpcName, {
      p_fournisseur: provider, p_charge: charge, p_signature: signature
    });
  } catch (error) {
    const code = error instanceof SupabaseRpcFailure && error.code === "RPC_CONFIGURATION_INVALID"
      ? "PERSISTENCE_NOT_CONFIGURED" : "PERSISTENCE_UNAVAILABLE";
    throw new HttpFailure(503, code);
  }
  if (!object(result) || result.ok !== true) throw new HttpFailure(503, "PERSISTENCE_NOT_CONFIRMED");
  return result;
}

export function createWebhookHandler({ env = {}, fetchImpl = fetch, now = () => Date.now(), persist = null } = {}) {
  const persistEvent = persist ?? (args => persistWithSupabase({ ...args, env, fetchImpl, now }));
  return async request => {
    try {
      const url = new URL(request.url);
      const provider = url.pathname.split("/").filter(Boolean).at(-1);
      if (!["meta", "brevo", "resend"].includes(provider)) return jsonResponse(404, { ok: false });

      if (provider === "meta" && request.method === "GET") {
        const mode = url.searchParams.get("hub.mode");
        const challenge = url.searchParams.get("hub.challenge");
        const supplied = url.searchParams.get("hub.verify_token");
        const expected = envValue(env, "META_VERIFY_TOKEN");
        if (mode !== "subscribe" || !challenge || !expected || !safeEqual(supplied, expected)) {
          return textResponse(403, "Forbidden");
        }
        return textResponse(200, challenge);
      }
      if (request.method !== "POST") return jsonResponse(405, { ok: false });

      const raw = await readBoundedBody(request);
      if (provider === "meta") {
        const valid = await verifyMetaSignature(raw, request.headers.get("x-hub-signature-256"), envValue(env, "META_APP_SECRET"));
        if (!valid) return jsonResponse(401, { ok: false });
      } else if (provider === "brevo") {
        if (!verifyBrevoBearer(request.headers, envValue(env, "BREVO_WEBHOOK_BEARER_TOKEN"))) return jsonResponse(401, { ok: false });
      } else {
        const valid = await verifyResendSignature(request.headers, raw, envValue(env, "RESEND_WEBHOOK_SECRET"), now());
        if (!valid) return jsonResponse(401, { ok: false });
      }

      const payload = parseJson(raw);
      const events = provider === "meta" ? normalizeMeta(payload)
        : provider === "brevo" ? await normalizeBrevo(payload)
          : normalizeResend(payload, request.headers);
      let stored = 0;
      let replayed = 0;
      for (const item of events) {
        const result = await persistEvent({ provider: item.provider, event: item.event });
        if (result?.ok !== true) throw new HttpFailure(503, "PERSISTENCE_NOT_CONFIRMED");
        if (result.rejeu === true) replayed += 1;
        else stored += 1;
      }
      return jsonResponse(200, { ok: true, stored, replayed, ignored: events.length === 0 });
    } catch (error) {
      if (error instanceof HttpFailure) return jsonResponse(error.status, { ok: false, code: error.code });
      return jsonResponse(500, { ok: false, code: "INTERNAL_ERROR" });
    }
  };
}
