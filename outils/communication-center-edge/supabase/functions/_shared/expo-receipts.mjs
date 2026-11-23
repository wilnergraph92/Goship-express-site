const EXPO_RECEIPTS_URL = "https://exp.host/--/api/v2/push/getReceipts";
const MAX_TICKETS = 1_000;
const AVAILABLE_AFTER_MS = 15 * 60 * 1_000;
const RETAINED_FOR_MS = 24 * 60 * 60 * 1_000;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function response(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}

function secureEqual(left, right) {
  const a = new TextEncoder().encode(String(left ?? ""));
  const b = new TextEncoder().encode(String(right ?? ""));
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

function ticketIdIsValid(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

export async function reconcileExpoReceipts(tickets, { fetchImpl = fetch, now = Date.now } = {}) {
  if (!Array.isArray(tickets) || tickets.length > MAX_TICKETS) throw new TypeError("TICKETS_INVALID");
  const current = now();
  const results = new Map();
  const due = [];

  for (const ticket of tickets) {
    if (!isObject(ticket) || !ticketIdIsValid(ticket.id) || typeof ticket.accepted_at !== "string") {
      throw new TypeError("TICKET_INVALID");
    }
    const acceptedAt = Date.parse(ticket.accepted_at);
    if (!Number.isFinite(acceptedAt) || acceptedAt > current) throw new TypeError("TICKET_DATE_INVALID");
    const age = current - acceptedAt;
    if (age < AVAILABLE_AFTER_MS) {
      results.set(ticket.id, { ticket_id: ticket.id, state: "pending" });
    } else if (age >= RETAINED_FOR_MS) {
      results.set(ticket.id, { ticket_id: ticket.id, state: "expired" });
    } else {
      due.push(ticket.id);
    }
  }

  for (let offset = 0; offset < due.length; offset += MAX_TICKETS) {
    const ids = due.slice(offset, offset + MAX_TICKETS);
    let responseFromExpo;
    try {
      responseFromExpo = await fetchImpl(EXPO_RECEIPTS_URL, {
        method: "POST",
        redirect: "error",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ ids })
      });
    } catch {
      throw new Error("EXPO_RECEIPT_SERVICE_UNAVAILABLE");
    }
    if (!responseFromExpo.ok) throw new Error("EXPO_RECEIPT_SERVICE_UNAVAILABLE");

    let payload;
    try { payload = await responseFromExpo.json(); } catch { throw new Error("EXPO_RECEIPT_RESPONSE_INVALID"); }
    if (!isObject(payload) || !isObject(payload.data)) throw new Error("EXPO_RECEIPT_RESPONSE_INVALID");

    for (const id of ids) {
      const receipt = payload.data[id];
      if (!isObject(receipt)) {
        results.set(id, { ticket_id: id, state: "pending" });
      } else if (receipt.status === "ok") {
        // Expo confirme le passage vers FCM/APNs, pas la réception par le terminal.
        results.set(id, { ticket_id: id, state: "handoff_confirmed" });
      } else if (receipt.status === "error") {
        const providerCode = receipt.details?.error;
        const code = providerCode === "DeviceNotRegistered" ? "DEVICE_NOT_REGISTERED" : "EXPO_RECEIPT_ERROR";
        results.set(id, { ticket_id: id, state: "failed", code });
      } else {
        results.set(id, { ticket_id: id, state: "pending" });
      }
    }
  }

  return tickets.map(ticket => results.get(ticket.id));
}

async function readBody(request, maxBytes = 200_000) {
  const length = Number(request.headers.get("content-length"));
  if (Number.isFinite(length) && length > maxBytes) throw new TypeError("BODY_TOO_LARGE");
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
        throw new TypeError("BODY_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

export function createExpoReceiptHandler({
  env = {}, fetchImpl = fetch, now = Date.now
} = {}) {
  const envValue = name => typeof env === "function" ? env(name) ?? "" : env?.[name] ?? "";
  return async request => {
    try {
      if (request.method !== "POST") return response(405, { ok: false });
      const token = envValue("COMMUNICATION_EXPO_RECEIPT_TRIGGER_TOKEN");
      const authorization = request.headers.get("authorization") ?? "";
      const match = /^Bearer (\S{1,2048})$/i.exec(authorization);
      if (!token || !match || !secureEqual(match[1], token)) return response(401, { ok: false });

      const payload = JSON.parse(await readBody(request));
      if (!isObject(payload) || !Array.isArray(payload.tickets) || payload.tickets.length > MAX_TICKETS) {
        return response(400, { ok: false, code: "TICKETS_INVALID" });
      }
      const results = await reconcileExpoReceipts(payload.tickets, { fetchImpl, now });
      return response(200, { ok: true, results });
    } catch (error) {
      const code = error?.message === "BODY_TOO_LARGE" ? "BODY_TOO_LARGE"
        : error?.message === "EXPO_RECEIPT_SERVICE_UNAVAILABLE" ? "EXPO_UNAVAILABLE"
          : error?.message === "EXPO_RECEIPT_RESPONSE_INVALID" ? "EXPO_RESPONSE_INVALID"
            : "REQUEST_INVALID";
      const status = code === "EXPO_UNAVAILABLE" ? 503 : code === "EXPO_RESPONSE_INVALID" ? 502 : 400;
      return response(status, { ok: false, code });
    }
  };
}
