const encoder = new TextEncoder();

function safeEqual(left, right) {
  const a = encoder.encode(String(left ?? ""));
  const b = encoder.encode(String(right ?? ""));
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return difference === 0;
}

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}

function readEnv(env, name) {
  return typeof env === "function" ? env(name) ?? "" : env?.[name] ?? "";
}

async function parseLimit(request) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > 1_024) throw new Error("BODY_TOO_LARGE");
  if (!request.body) return 50;
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 1_024) {
        await reader.cancel();
        throw new Error("BODY_TOO_LARGE");
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
  let body = {};
  if (bytes.byteLength) body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  if (body === null || typeof body !== "object" || Array.isArray(body)) throw new Error("BODY_INVALID");
  const rawLimit = body.limit ?? 50;
  if (!Number.isInteger(rawLimit) || rawLimit < 1 || rawLimit > 200) throw new Error("LIMIT_INVALID");
  return rawLimit;
}

/**
 * Enveloppe HTTP du travailleur, sans ordonnanceur ni identifiants de base.
 * L'adaptateur P-08 doit lui-même respecter SKIP LOCKED, l'ordre SQL des verrous
 * et les reprises prévues ; la file métier n'est pas reproduite ici.
 */
export function createWorkerHandler({
  env = {},
  processPrioritizedP08,
  processTransactionalOutbox,
  reconcileExpo,
  processWhatsappConfirmations
} = {}) {
  return async request => {
    if (request.method !== "POST") return json(405, { ok: false });
    const trigger = readEnv(env, "COMMUNICATION_WORKER_TRIGGER_TOKEN");
    const match = /^Bearer (\S{1,2048})$/i.exec(request.headers.get("authorization") ?? "");
    if (!trigger || !match || !safeEqual(match[1], trigger)) return json(401, { ok: false });

    let limit;
    try { limit = await parseLimit(request); } catch (error) {
      const code = error?.message === "BODY_TOO_LARGE" ? "BODY_TOO_LARGE" : "REQUEST_INVALID";
      return json(400, { ok: false, code });
    }
    if (![processPrioritizedP08, processTransactionalOutbox, reconcileExpo,
          processWhatsappConfirmations].every(fn => typeof fn === "function")) {
      return json(503, { ok: false, code: "WORKER_ADAPTER_NOT_CONFIGURED" });
    }

    try {
      // STOP et autres priorités P-09 précèdent les reçus et toute nouvelle sortie.
      const p08 = await processPrioritizedP08({ limit });
      if (p08?.ok !== true || !Number.isInteger(p08.prioritaire_en_attente)
          || p08.prioritaire_en_attente < 0 || p08.prioritaire_en_attente > 0) {
        return json(503, { ok: false, code: "P08_PRIORITY_UNRESOLVED" });
      }
      const recusExpo = await reconcileExpo({ limit });
      const confirmationsWhatsapp = await processWhatsappConfirmations({ limit });
      const transactionnel = await processTransactionalOutbox({ limit });
      return json(200, { ok: true, p08, transactionnel, recus_expo: recusExpo,
        confirmations_whatsapp: confirmationsWhatsapp });
    } catch {
      // Le fournisseur ne voit ni détails SQL, ni données client, ni secret.
      return json(503, { ok: false, code: "WORKER_TEMPORARILY_UNAVAILABLE" });
    }
  };
}
