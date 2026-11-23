import test from "node:test";
import assert from "node:assert/strict";
import {
  createWebhookHandler,
  hmacSha256Hex,
  normalizeBrevo,
  normalizeMeta,
  normalizeResend,
  verifyMetaSignature,
  verifyResendSignature
} from "../communication-center-edge/supabase/functions/_shared/webhook-adapters.mjs";
import {
  createExpoReceiptHandler,
  reconcileExpoReceipts
} from "../communication-center-edge/supabase/functions/_shared/expo-receipts.mjs";
import {
  createWorkerHandler
} from "../communication-center-edge/supabase/functions/_shared/worker-orchestrator.mjs";
import { createWorkerAdapters } from "../communication-center-edge/supabase/functions/_shared/worker-adapters.mjs";
import { createWhatsappConfirmationSender } from "../communication-center-edge/supabase/functions/_shared/whatsapp-template-adapter.mjs";
import { createSupabaseRpcClient } from "../communication-center-edge/supabase/functions/_shared/supabase-rpc.mjs";
import { createCommunicationJwtSigner } from "../communication-center-edge/supabase/functions/_shared/communication-jwt.mjs";

const encoder = new TextEncoder();
const now = Date.parse("2026-11-22T15:00:00.000Z");
const metaSecret = "synthetic-meta-app-secret";
const brevoToken = "synthetic-brevo-bearer-token";
const resendKey = "synthetic-resend-webhook-signing-key";
const resendSecret = `whsec_${Buffer.from(resendKey).toString("base64")}`;
const workerToken = "synthetic-worker-trigger-token";
const expoToken = "synthetic-expo-receipt-trigger-token";

const signerKeyPair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]
);
const signerPrivateJwk = {
  ...await crypto.subtle.exportKey("jwk", signerKeyPair.privateKey),
  kid: "goship-edge-test-key",
  alg: "ES256",
  key_ops: ["sign"]
};
const signerPublicJwk = {
  ...await crypto.subtle.exportKey("jwk", signerKeyPair.publicKey),
  kid: "goship-edge-test-key",
  alg: "ES256",
  key_ops: ["verify"]
};
const rotationKeyPair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]
);
const rotationPrivateJwk = {
  ...await crypto.subtle.exportKey("jwk", rotationKeyPair.privateKey),
  kid: "goship-edge-rotation-test-key",
  alg: "ES256",
  key_ops: ["sign"]
};
const rotationPublicJwk = {
  ...await crypto.subtle.exportKey("jwk", rotationKeyPair.publicKey),
  kid: "goship-edge-rotation-test-key",
  alg: "ES256",
  key_ops: ["verify"]
};

function rpcEnv(role, values = {}) {
  return env({
    SUPABASE_URL: "http://127.0.0.1:54321",
    SUPABASE_PUBLISHABLE_KEY: "synthetic-publishable-key",
    COMMUNICATION_JWT_PRIVATE_KEYS: JSON.stringify([signerPrivateJwk]),
    COMMUNICATION_JWT_ACTIVE_KID: signerPrivateJwk.kid,
    COMMUNICATION_JWT_ISSUER: "goship-synthetic-issuer",
    COMMUNICATION_JWT_AUDIENCE: "goship-synthetic-postgrest",
    COMMUNICATION_JWT_MAX_TTL_SECONDS: "300",
    COMMUNICATION_WEBHOOK_JWT_TTL: "60",
    COMMUNICATION_WORKER_JWT_TTL: "90",
    [`${role === "communication_worker" ? "COMMUNICATION_WORKER" : "COMMUNICATION_WEBHOOK"}_JWT_TTL`]:
      role === "communication_worker" ? "90" : "60",
    ...values
  });
}

function decodeBase64Url(value) {
  return new Uint8Array(Buffer.from(value, "base64url"));
}

async function verifySyntheticJwt(token, expectedRole, {
  at = now,
  issuer = "goship-synthetic-issuer",
  audience = "goship-synthetic-postgrest",
  publicJwk = signerPublicJwk
} = {}) {
  const parts = String(token).split(".");
  assert.equal(parts.length, 3);
  const header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
  const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  const publicKey = await crypto.subtle.importKey(
    "jwk", publicJwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, publicKey,
    decodeBase64Url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`)
  );
  assert.equal(valid, true);
  assert.equal(header.alg, "ES256");
  assert.equal(header.typ, "JWT");
  assert.equal(header.kid, publicJwk.kid);
  assert.equal(claims.iss, issuer);
  assert.equal(claims.aud, audience);
  assert.equal(claims.role, expectedRole);
  assert.equal(Object.hasOwn(claims, "sub"), false);
  assert.equal(Number.isInteger(claims.iat), true);
  assert.equal(Number.isInteger(claims.nbf), true);
  assert.equal(Number.isInteger(claims.exp), true);
  assert.equal(claims.nbf, claims.iat);
  assert.ok(claims.iat <= Math.floor(at / 1_000));
  assert.ok(claims.nbf <= Math.floor(at / 1_000));
  assert.ok(claims.exp > Math.floor(at / 1_000));
  assert.ok(claims.exp - claims.iat <= (expectedRole === "communication_worker" ? 90 : 60));
  assert.equal(typeof claims.jti, "string");
  return claims;
}

async function resendHeaders(rawBody, timestamp = String(Math.floor(now / 1_000)), id = "msg_synthetic_1") {
  const key = await crypto.subtle.importKey("raw", encoder.encode(resendKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${id}.${timestamp}.${rawBody}`)));
  const encoded = Buffer.from(signature).toString("base64");
  return new Headers({
    "svix-id": id,
    "svix-timestamp": timestamp,
    "svix-signature": `v1,${encoded}`
  });
}

function metaPayload() {
  return {
    object: "whatsapp_business_account",
    entry: [{ changes: [{ field: "messages", value: {
      statuses: [{ id: "wamid.synthetic", status: "delivered", timestamp: "1795360000" }]
    } }] }]
  };
}

function env(values = {}) {
  return {
    META_APP_SECRET: metaSecret,
    META_VERIFY_TOKEN: "synthetic-verify-token",
    BREVO_WEBHOOK_BEARER_TOKEN: brevoToken,
    RESEND_WEBHOOK_SECRET: resendSecret,
    COMMUNICATION_WEBHOOK_HMAC_SECRET: "synthetic-shared-hmac-secret",
    COMMUNICATION_WORKER_TRIGGER_TOKEN: workerToken,
    COMMUNICATION_EXPO_RECEIPT_TRIGGER_TOKEN: expoToken,
    ...values
  };
}

test("Meta vérifie une signature HMAC-SHA-256 valide et refuse le corps modifié", async () => {
  const raw = JSON.stringify(metaPayload());
  const valid = `sha256=${await hmacSha256Hex(metaSecret, raw)}`;
  assert.equal(await verifyMetaSignature(raw, valid, metaSecret), true);
  assert.equal(await verifyMetaSignature(`${raw} `, valid, metaSecret), false);
  assert.equal(await verifyMetaSignature(raw, "", metaSecret), false);
});

test("Meta répond au challenge uniquement avec le jeton attendu", async () => {
  const handler = createWebhookHandler({ env: env(), persist: async () => ({ ok: true }) });
  const good = await handler(new Request("https://edge.test/communication-webhooks/meta?hub.mode=subscribe&hub.challenge=challenge-1&hub.verify_token=synthetic-verify-token"));
  const bad = await handler(new Request("https://edge.test/communication-webhooks/meta?hub.mode=subscribe&hub.challenge=challenge-1&hub.verify_token=wrong"));
  assert.equal(good.status, 200);
  assert.equal(await good.text(), "challenge-1");
  assert.equal(bad.status, 403);
});

test("Meta n'appelle le RPC qu'après signature valide et succès de persistance", async () => {
  const raw = JSON.stringify(metaPayload());
  const calls = [];
  const handler = createWebhookHandler({
    env: env(),
    persist: async event => { calls.push(event); return { ok: true, enregistre: true }; }
  });
  const invalid = await handler(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": `sha256=${"0".repeat(64)}` }, body: raw
  }));
  assert.equal(invalid.status, 401);
  assert.equal(calls.length, 0);

  const signature = `sha256=${await hmacSha256Hex(metaSecret, raw)}`;
  const valid = await handler(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": signature }, body: raw
  }));
  assert.equal(valid.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].event.type, "delivered");
  assert.match(calls[0].event.id, /^meta:wamid\.synthetic:delivered:/);

  const persistenceFailed = createWebhookHandler({
    env: env(), persist: async () => ({ ok: false })
  });
  const failed = await persistenceFailed(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": signature }, body: raw
  }));
  assert.equal(failed.status, 503);
});

test("Meta normalise un STOP entrant sans renvoyer ses données dans la réponse HTTP", async () => {
  const payload = { object: "whatsapp_business_account", entry: [{ changes: [{ field: "messages", value: {
    messages: [{ id: "wamid.inbound.synthetic", from: "+18095550123", timestamp: "1795360000", text: { body: "STOP" } }]
  } }] }] };
  const normalized = normalizeMeta(payload);
  assert.equal(normalized.length, 1);
  assert.equal(normalized[0].event.type, "inbound");
  assert.equal(normalized[0].event.telephone, "+18095550123");
  assert.equal(normalized[0].event.texte, "STOP");

  const raw = JSON.stringify(payload);
  const signature = `sha256=${await hmacSha256Hex(metaSecret, raw)}`;
  const handler = createWebhookHandler({ env: env(), persist: async () => ({ ok: true, enregistre: true }) });
  const response = await handler(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": signature }, body: raw
  }));
  const body = await response.text();
  assert.equal(response.status, 200);
  assert.equal(body.includes("18095550123"), false);
  assert.equal(body.includes("STOP"), false);
});

test("Brevo exige un Bearer valide et ne conserve que les champs nécessaires", async () => {
  let persisted;
  const handler = createWebhookHandler({
    env: env(), persist: async value => { persisted = value; return { ok: true, enregistre: true }; }
  });
  const raw = JSON.stringify({ event: "hardBounce", "message-id": "brevo-message-1", ts_event: 1795360000, email: "synthetic@example.invalid", reason: "private reason" });
  const denied = await handler(new Request("https://edge.test/communication-webhooks/brevo", {
    method: "POST", headers: { authorization: "Bearer wrong" }, body: raw
  }));
  assert.equal(denied.status, 401);
  assert.equal(persisted, undefined);

  const accepted = await handler(new Request("https://edge.test/communication-webhooks/brevo", {
    method: "POST", headers: { authorization: `Bearer ${brevoToken}` }, body: raw
  }));
  assert.equal(accepted.status, 200);
  assert.equal(persisted.event.type, "hard_bounce");
  assert.equal(JSON.stringify(persisted.event).includes("synthetic@example.invalid"), false);
  assert.equal(JSON.stringify(persisted.event).includes("private reason"), false);
  assert.equal((await normalizeBrevo({ event: "opened", "message-id": "x", ts_event: 1795360000 })).length, 0);
  const privateMessageId = await normalizeBrevo({
    event: "delivered", "message-id": "<synthetic@example.invalid>", ts_event: 1795360000
  });
  assert.match(privateMessageId[0].event.id, /^brevo:[0-9a-f]{64}$/);
  assert.equal(privateMessageId[0].event.id.includes("synthetic@example.invalid"), false);
});

test("Resend vérifie Svix sur le corps brut, la signature, l'identifiant et une fenêtre de cinq minutes", async () => {
  const raw = JSON.stringify({ type: "email.delivered", created_at: "2026-11-22T14:59:00.000Z", data: { email_id: "resend-email-1" } });
  const headers = await resendHeaders(raw);
  assert.equal(await verifyResendSignature(headers, raw, resendSecret, now), true);
  assert.equal(await verifyResendSignature(headers, `${raw} `, resendSecret, now), false);
  assert.equal(await verifyResendSignature(headers, raw, resendSecret, now + 301_000), false);
  assert.equal(await verifyResendSignature(new Headers(), raw, resendSecret, now), false);
  const normalized = normalizeResend(JSON.parse(raw), headers);
  assert.equal(normalized[0].event.type, "delivered");
  assert.equal(normalized[0].event.message_id, "resend-email-1");
});

test("Resend ne confirme pas un contact.unsubscribe sans correspondance GoShip", () => {
  const headers = new Headers({ "svix-id": "msg_contact" });
  assert.throws(
    () => normalizeResend({ type: "contact.updated", data: { id: "contact-1", unsubscribed: true } }, headers),
    /RESEND_CONTACT_CORRELATION_UNAVAILABLE/
  );
});

test("l'authentification RPC Supabase manquante échoue fermé sans utiliser service_role", async () => {
  const raw = JSON.stringify(metaPayload());
  const signature = `sha256=${await hmacSha256Hex(metaSecret, raw)}`;
  const handler = createWebhookHandler({
    env: env(),
    fetchImpl: async () => { throw new Error("unexpected network"); }
  });
  const result = await handler(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": signature }, body: raw
  }));
  assert.equal(result.status, 503);
  assert.equal((await result.json()).code, "PERSISTENCE_NOT_CONFIGURED");
});

test("les statuts transactionnels et les événements génériques utilisent leurs RPC P-08 respectifs", async () => {
  const raw = JSON.stringify(metaPayload());
  const signature = `sha256=${await hmacSha256Hex(metaSecret, raw)}`;
  const requests = [];
  const handler = createWebhookHandler({
    env: rpcEnv("communication_webhook", {
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "synthetic-publishable-key" }),
    }),
    now: () => now,
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), headers: options.headers, body: JSON.parse(options.body) });
      return new Response(JSON.stringify({ ok: true, enregistre: true }), { status: 200 });
    }
  });
  const response = await handler(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": signature }, body: raw
  }));
  assert.equal(response.status, 200);
  assert.match(requests[0].url, /\/rpc\/communication_edge_webhook_recevoir_statut_transactionnel$/);
  await verifySyntheticJwt(requests[0].headers.authorization.slice("Bearer ".length), "communication_webhook");
  assert.equal(requests[0].headers["content-profile"], "communication_edge");
  assert.equal("SUPABASE_SERVICE_ROLE_KEY" in requests[0].headers, false);
  const charge = JSON.parse(requests[0].body.p_charge);
  assert.equal(requests[0].body.p_signature, await hmacSha256Hex(
    "synthetic-shared-hmac-secret", `meta:${requests[0].body.p_charge}`
  ));
  assert.equal(charge.type, "delivered");

  const inbound = { object: "whatsapp_business_account", entry: [{ changes: [{ field: "messages", value: {
    messages: [{ id: "wamid.inbound.route", from: "+18095550123", text: { body: "STOP" } }]
  } }] }] };
  const inboundRaw = JSON.stringify(inbound);
  const inboundSignature = `sha256=${await hmacSha256Hex(metaSecret, inboundRaw)}`;
  await handler(new Request("https://edge.test/communication-webhooks/meta", {
    method: "POST", headers: { "x-hub-signature-256": inboundSignature }, body: inboundRaw
  }));
  assert.match(requests[1].url, /\/rpc\/communication_edge_webhook_recevoir_evenement$/);
  await verifySyntheticJwt(requests[1].headers.authorization.slice("Bearer ".length), "communication_webhook");
  assert.equal(JSON.parse(requests[1].body.p_charge).type, "inbound");
});

test("le client RPC refuse les rôles non dédiés et limite les appels à sa liste RPC", async () => {
  let requests = 0;
  const makeClient = expectedRole => createSupabaseRpcClient({
    env: rpcEnv(expectedRole),
    expectedRole,
    fetchImpl: async () => { requests += 1; return new Response("{}", { status: 200 }); }
  });
  await assert.rejects(makeClient("authenticated")("communication_edge_webhook_recevoir_evenement", {}), /RPC_NOT_ALLOWED/);
  await assert.rejects(makeClient("service_role")("communication_edge_webhook_recevoir_evenement", {}), /RPC_NOT_ALLOWED/);
  await assert.rejects(makeClient("communication_worker")("communication_edge_webhook_recevoir_evenement", {}), /RPC_NOT_ALLOWED/);
  assert.equal(requests, 0);

  const call = createSupabaseRpcClient({
    env: rpcEnv("communication_webhook", {
      SUPABASE_URL: "https://project.supabase.co",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "synthetic-publishable-key" })
    }),
    expectedRole: "communication_webhook",
    now: () => now,
    fetchImpl: async (url, options) => {
      requests += 1;
      assert.equal(String(url), "https://project.supabase.co/rest/v1/rpc/communication_edge_webhook_recevoir_evenement");
      assert.equal(options.headers["content-profile"], "communication_edge");
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }
  });
  assert.deepEqual(await call("communication_edge_webhook_recevoir_evenement", { p_fournisseur: "meta" }), { ok: true });
  await assert.rejects(call("communication_edge_worker_traiter_notifications", {}), /RPC_NOT_ALLOWED/);
  await assert.rejects(call("communication_edge_worker_code_whatsapp_pour_envoi", {}), /RPC_NOT_ALLOWED/);
  assert.equal(requests, 1);
});

test("le signer ES256 exige une configuration bornée et refuse un rôle non autorisé", async () => {
  const sign = createCommunicationJwtSigner({ env: rpcEnv("communication_webhook"), now: () => now });
  const token = await sign("communication_webhook");
  await verifySyntheticJwt(token, "communication_webhook");
  await assert.rejects(sign("service_role"), /JWT_CONFIGURATION_INVALID/);

  const tooLong = createCommunicationJwtSigner({
    env: rpcEnv("communication_webhook", { COMMUNICATION_WEBHOOK_JWT_TTL: "301" }),
    now: () => now
  });
  await assert.rejects(tooLong("communication_webhook"), /JWT_CONFIGURATION_INVALID/);

  const missing = createCommunicationJwtSigner({
    env: env({ COMMUNICATION_JWT_PRIVATE_KEYS: JSON.stringify([signerPrivateJwk]) }),
    now: () => now
  });
  await assert.rejects(missing("communication_webhook"), /JWT_CONFIGURATION_INVALID/);

  const expiredSigner = createCommunicationJwtSigner({
    env: rpcEnv("communication_webhook"), now: () => now - 120_000
  });
  const expired = await expiredSigner("communication_webhook");
  await assert.rejects(verifySyntheticJwt(expired, "communication_webhook", { at: now }), { code: "ERR_ASSERTION" });

  const notYetValidSigner = createCommunicationJwtSigner({
    env: rpcEnv("communication_webhook"), now: () => now + 120_000
  });
  const notYetValid = await notYetValidSigner("communication_webhook");
  await assert.rejects(verifySyntheticJwt(notYetValid, "communication_webhook", { at: now }), { code: "ERR_ASSERTION" });

  const wrongIssuerSigner = createCommunicationJwtSigner({
    env: rpcEnv("communication_webhook", { COMMUNICATION_JWT_ISSUER: "untrusted-test-issuer" }),
    now: () => now
  });
  await assert.rejects(verifySyntheticJwt(await wrongIssuerSigner("communication_webhook"), "communication_webhook"), { code: "ERR_ASSERTION" });

  const wrongAudienceSigner = createCommunicationJwtSigner({
    env: rpcEnv("communication_webhook", { COMMUNICATION_JWT_AUDIENCE: "untrusted-test-audience" }),
    now: () => now
  });
  await assert.rejects(verifySyntheticJwt(await wrongAudienceSigner("communication_webhook"), "communication_webhook"), { code: "ERR_ASSERTION" });

  const workerSigner = createCommunicationJwtSigner({ env: rpcEnv("communication_worker"), now: () => now });
  await assert.rejects(verifySyntheticJwt(await workerSigner("communication_worker"), "communication_webhook"), { code: "ERR_ASSERTION" });

  const rotationSigner = createCommunicationJwtSigner({
    env: rpcEnv("communication_worker", {
      COMMUNICATION_JWT_PRIVATE_KEYS: JSON.stringify([signerPrivateJwk, rotationPrivateJwk]),
      COMMUNICATION_JWT_ACTIVE_KID: rotationPrivateJwk.kid
    }),
    now: () => now
  });
  const rotated = await rotationSigner("communication_worker");
  await verifySyntheticJwt(rotated, "communication_worker", { publicJwk: rotationPublicJwk });

  const tokenParts = token.split(".");
  const damagedSignature = decodeBase64Url(tokenParts[2]);
  damagedSignature[0] ^= 1;
  tokenParts[2] = Buffer.from(damagedSignature).toString("base64url");
  const tampered = tokenParts.join(".");
  const tamperedKey = await crypto.subtle.importKey(
    "jwk", signerPublicJwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]
  );
  const tamperedParts = tampered.split(".");
  const tamperedValid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, tamperedKey,
    decodeBase64Url(tamperedParts[2]), new TextEncoder().encode(`${tamperedParts[0]}.${tamperedParts[1]}`)
  );
  assert.equal(tamperedValid, false);
});

test("Expo ne consulte pas avant 15 minutes et ne confond pas prise en charge fournisseur et terminal", async () => {
  const tickets = [
    { id: "123e4567-e89b-42d3-a456-426614174000", accepted_at: new Date(now - 10 * 60_000).toISOString() },
    { id: "123e4567-e89b-42d3-a456-426614174001", accepted_at: new Date(now - 20 * 60_000).toISOString() },
    { id: "123e4567-e89b-42d3-a456-426614174002", accepted_at: new Date(now - 25 * 60 * 60_000).toISOString() }
  ];
  let called = false;
  const results = await reconcileExpoReceipts(tickets, {
    now: () => now,
    fetchImpl: async (url, options) => {
      called = true;
      assert.equal(url, "https://exp.host/--/api/v2/push/getReceipts");
      assert.equal(options.redirect, "error");
      const { ids } = JSON.parse(options.body);
      assert.deepEqual(ids, [tickets[1].id]);
      return new Response(JSON.stringify({ data: { [tickets[1].id]: { status: "ok" } } }), { status: 200 });
    }
  });
  assert.equal(called, true);
  assert.deepEqual(results.map(result => result.state), ["pending", "handoff_confirmed", "expired"]);
  assert.notEqual(results[1].state, "delivered_to_device");
});

test("Expo classe DeviceNotRegistered sans stocker le texte du fournisseur", async () => {
  const ticket = { id: "123e4567-e89b-42d3-a456-426614174003", accepted_at: new Date(now - 20 * 60_000).toISOString() };
  const results = await reconcileExpoReceipts([ticket], {
    now: () => now,
    fetchImpl: async () => new Response(JSON.stringify({ data: {
      [ticket.id]: { status: "error", message: "synthetic private response", details: { error: "DeviceNotRegistered" } }
    } }), { status: 200 })
  });
  assert.deepEqual(results, [{ ticket_id: ticket.id, state: "failed", code: "DEVICE_NOT_REGISTERED" }]);
});

test("l'endpoint Expo est protégé et n'accepte que les lots internes", async () => {
  let outboundCalls = 0;
  const handler = createExpoReceiptHandler({
    env: env(), now: () => now,
    fetchImpl: async () => { outboundCalls += 1; return new Response(JSON.stringify({ data: {} }), { status: 200 }); }
  });
  const bad = await handler(new Request("https://edge.test/communication-expo-receipts", { method: "POST", body: "{}" }));
  assert.equal(bad.status, 401);
  assert.equal(outboundCalls, 0);
  const valid = await handler(new Request("https://edge.test/communication-expo-receipts", {
    method: "POST",
    headers: { authorization: `Bearer ${expoToken}`, "content-type": "application/json" },
    body: JSON.stringify({ tickets: [{ id: "123e4567-e89b-42d3-a456-426614174004", accepted_at: new Date(now - 20 * 60_000).toISOString() }] })
  }));
  assert.equal(valid.status, 200);
  assert.equal(outboundCalls, 1);
});

test("le worker P-08 prioritaire précède les transmissions et bloque l'envoi si un urgent reste", async () => {
  const calls = [];
  const handler = createWorkerHandler({
    env: env(),
    processPrioritizedP08: async () => { calls.push("p08"); return { ok: true, prioritaire_en_attente: 1 }; },
    processTransactionalOutbox: async () => { calls.push("transactionnel"); return { processed: 1 }; },
    reconcileExpo: async () => { calls.push("expo"); return { checked: 1 }; },
    processWhatsappConfirmations: async () => { calls.push("confirmation"); return { attempted: 0 }; }
  });
  const response = await handler(new Request("https://edge.test/communication-worker", {
    method: "POST", headers: { authorization: `Bearer ${workerToken}`, "content-type": "application/json" }, body: "{\"limit\":10}"
  }));
  assert.equal(response.status, 503);
  assert.deepEqual(calls, ["p08"]);
});

test("le worker traite P-08, Expo, les confirmations puis l'outbox avec une limite bornée", async () => {
  const calls = [];
  const handler = createWorkerHandler({
    env: env(),
    processPrioritizedP08: async ({ limit }) => { calls.push(["p08", limit]); return { ok: true, prioritaire_en_attente: 0, processed: 2 }; },
    processTransactionalOutbox: async ({ limit }) => { calls.push(["transactionnel", limit]); return { processed: 1 }; },
    reconcileExpo: async ({ limit }) => { calls.push(["expo", limit]); return { checked: 1 }; },
    processWhatsappConfirmations: async ({ limit }) => { calls.push(["confirmation", limit]); return { attempted: 0 }; }
  });
  const response = await handler(new Request("https://edge.test/communication-worker", {
    method: "POST", headers: { authorization: `Bearer ${workerToken}`, "content-type": "application/json" }, body: "{\"limit\":25}"
  }));
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [["p08", 25], ["expo", 25], ["confirmation", 25], ["transactionnel", 25]]);
});

test("les adaptateurs du worker relient ses RPC P-08, Expo et C2/C3 sans transport réel", async () => {
  const calls = [];
  const ticket = "123e4567-e89b-42d3-a456-426614174099";
  const adapters = createWorkerAdapters({
    env: rpcEnv("communication_worker", {
      SUPABASE_URL: "http://localhost:54321",
      SUPABASE_PUBLISHABLE_KEY: "synthetic-publishable-key",
    }),
    now: () => now,
    fetchImpl: async (url, options = {}) => {
      const address = String(url);
      if (address === "https://exp.host/--/api/v2/push/getReceipts") {
        calls.push("expo_receipt_api");
        return new Response(JSON.stringify({ data: { [ticket]: { status: "ok" } } }), { status: 200 });
      }
      const rpc = new URL(address).pathname.split("/").at(-1);
      await verifySyntheticJwt(options.headers.authorization.slice("Bearer ".length), "communication_worker");
      calls.push(rpc);
      if (rpc === "communication_edge_worker_traiter_evenements_prioritaires") {
        return new Response(JSON.stringify({ ok: true, traites: 1, prioritaire_en_attente: 0 }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_expo_recus_a_reconcilier") {
        return new Response(JSON.stringify({ tickets: [{ id: ticket, accepted_at: new Date(now - 20 * 60_000).toISOString() }] }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_expo_enregistrer_recus") {
        assert.deepEqual(JSON.parse(options.body).p_resultats, [
          { ticket_id: ticket, state: "handoff_confirmed" }
        ]);
        return new Response(JSON.stringify({ ok: true, mis_a_jour: 1 }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_traiter_notifications") {
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_reserver_confirmation_whatsapp") {
        const args = JSON.parse(options.body);
        return new Response(JSON.stringify({
          ok: true, claimed: true, envoi_id: 72,
          claim_id: args.p_claim_id, expire_le: "2026-11-22T15:05:00Z"
        }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_code_whatsapp_pour_envoi") {
        return new Response(JSON.stringify("654321"), { status: 200 });
      }
      throw new Error(`unexpected RPC: ${rpc}`);
    }
  });

  assert.deepEqual(await adapters.processPrioritizedP08({ limit: 10 }), {
    ok: true, traites: 1, prioritaire_en_attente: 0
  });
  assert.deepEqual(await adapters.reconcileExpo({ limit: 10 }), { ok: true, reconciled: 1, updated: 1 });
  assert.deepEqual(await adapters.processTransactionalOutbox({ limit: 10 }), { ok: true });
  const claim = await adapters.claimWhatsappConfirmation({
    envoiId: 72,
    claimId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  });
  assert.deepEqual(claim, {
    claimed: true,
    envoiId: 72,
    claimId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    expiresAt: "2026-11-22T15:05:00Z"
  });
  assert.equal(await adapters.retrieveWhatsappConfirmationCode({
    envoiId: 72,
    claimId: claim.claimId
  }), "654321");
  assert.deepEqual(calls, [
    "communication_edge_worker_traiter_evenements_prioritaires",
    "communication_edge_worker_expo_recus_a_reconcilier",
    "expo_receipt_api",
    "communication_edge_worker_expo_enregistrer_recus",
    "communication_edge_worker_traiter_notifications",
    "communication_edge_worker_reserver_confirmation_whatsapp",
    "communication_edge_worker_code_whatsapp_pour_envoi"
  ]);
});

test("la récupération WhatsApp refuse toute réponse de code mal formée sans l'exposer dans l'erreur", async () => {
  const adapters = createWorkerAdapters({
    env: rpcEnv("communication_worker"),
    now: () => now,
    fetchImpl: async () => new Response(JSON.stringify("synthetic-invalid-code-response"), { status: 200 })
  });
  await assert.rejects(
    adapters.retrieveWhatsappConfirmationCode({
      envoiId: 72,
      claimId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }),
    error => error.message === "WHATSAPP_CONFIRMATION_CODE_INVALID"
      && !error.message.includes("synthetic-invalid-code-response")
  );
});

test("l'adaptateur WhatsApp envoie le code uniquement dans le modèle Meta simulé", async () => {
  let request;
  const sender = createWhatsappConfirmationSender({
    env: {
      META_WHATSAPP_ACCESS_TOKEN: "synthetic-meta-access-token",
      META_WHATSAPP_PHONE_NUMBER_ID: "1234567890123",
      META_WHATSAPP_API_VERSION: "v23.0",
      META_WHATSAPP_CONFIRMATION_TEMPLATE: "goship_confirmation_code"
    },
    fetchImpl: async (url, options) => {
      request = { url: String(url), options, body: JSON.parse(options.body) };
      return new Response(JSON.stringify({ messages: [{ id: "wamid.synthetic-c73" }] }), { status: 200 });
    }
  });
  assert.equal(sender.isConfigured(), true);
  const result = await sender.send({ destination: "+18095550123", language: "en", code: "654321" });
  assert.deepEqual(result, { outcome: "accepte", messageId: "wamid.synthetic-c73" });
  assert.equal(request.url, "https://graph.facebook.com/v23.0/1234567890123/messages");
  assert.equal(request.options.method, "POST");
  assert.equal(request.options.redirect, "error");
  assert.match(request.options.headers.authorization, /^Bearer synthetic-meta-access-token$/);
  assert.equal(Object.keys(request.options.headers).some(key => key.toLowerCase() === "idempotency-key"), false);
  assert.deepEqual(request.body, {
    messaging_product: "whatsapp",
    to: "+18095550123",
    type: "template",
    template: {
      name: "goship_confirmation_code",
      language: { code: "en_US" },
      components: [{ type: "body", parameters: [{ type: "text", text: "654321" }] }]
    }
  });
});

test("l'adaptateur WhatsApp classe les résultats fournisseur sans relancer une transmission incertaine", async () => {
  const config = {
    META_WHATSAPP_ACCESS_TOKEN: "synthetic-meta-access-token",
    META_WHATSAPP_PHONE_NUMBER_ID: "1234567890123",
    META_WHATSAPP_API_VERSION: "v23.0",
    META_WHATSAPP_CONFIRMATION_TEMPLATE: "goship_confirmation_code"
  };
  for (const [status, payload, expected] of [
    [400, { error: { code: 130429 } }, { outcome: "temporaire", errorCode: "LIMITE_DEBIT" }],
    [400, { error: { code: 131016 } }, { outcome: "temporaire", errorCode: "ERREUR_FOURNISSEUR" }],
    [429, { error: { code: 132001 } }, { outcome: "definitif", errorCode: "REFUS_FOURNISSEUR" }],
    [429, { error: { message: "synthetic private response" } }, { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" }],
    [503, { error: { message: "synthetic private response" } }, { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" }],
    [200, { error: { message: "synthetic private response" } }, { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" }]
  ]) {
    const sender = createWhatsappConfirmationSender({
      env: config,
      fetchImpl: async () => new Response(JSON.stringify(payload), { status })
    });
    assert.deepEqual(await sender.send({ destination: "+18095550123", language: "fr", code: "654321" }), expected);
  }
  const unavailable = createWhatsappConfirmationSender({
    env: config,
    fetchImpl: async () => { throw new Error("synthetic network failure"); }
  });
  assert.deepEqual(await unavailable.send({ destination: "+18095550123", language: "fr", code: "654321" }), {
    outcome: "incertain", errorCode: "RESULTAT_INCERTAIN"
  });
  assert.equal(JSON.stringify(await unavailable.send({ destination: "+18095550123", language: "fr", code: "654321" }))
    .includes("synthetic network failure"), false);
});

test("le worker relie récupération, début, fournisseur simulé et résultat sans exposer le code", async () => {
  const calls = [];
  let claimCount = 0;
  let providerRequest;
  const adapters = createWorkerAdapters({
    env: rpcEnv("communication_worker", {
      META_WHATSAPP_ACCESS_TOKEN: "synthetic-meta-access-token",
      META_WHATSAPP_PHONE_NUMBER_ID: "1234567890123",
      META_WHATSAPP_API_VERSION: "v23.0",
      META_WHATSAPP_CONFIRMATION_TEMPLATE: "goship_confirmation_code"
    }),
    now: () => now,
    fetchImpl: async (url, options = {}) => {
      const address = String(url);
      if (address.startsWith("https://graph.facebook.com/")) {
        providerRequest = { url: address, options, body: JSON.parse(options.body) };
        calls.push("meta_simule");
        return new Response(JSON.stringify({ messages: [{ id: "wamid.synthetic-c73-worker" }] }), { status: 200 });
      }
      const rpc = new URL(address).pathname.split("/").at(-1);
      await verifySyntheticJwt(options.headers.authorization.slice("Bearer ".length), "communication_worker");
      calls.push(rpc);
      if (rpc === "communication_edge_worker_recuperer_confirmations_whatsapp") {
        return new Response(JSON.stringify({ ok: true, recovered: 0 }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_reserver_confirmation_whatsapp") {
        const args = JSON.parse(options.body);
        claimCount += 1;
        if (claimCount > 1) return new Response(JSON.stringify({ ok: true, claimed: false }), { status: 200 });
        return new Response(JSON.stringify({
          ok: true, claimed: true, envoi_id: 73, claim_id: args.p_claim_id,
          expire_le: "2026-11-22T15:05:00Z"
        }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_contexte_confirmation_whatsapp") {
        return new Response(JSON.stringify({ destinataire: "+18095550123", langue: "en" }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_code_whatsapp_pour_envoi") {
        return new Response(JSON.stringify("654321"), { status: 200 });
      }
      if (rpc === "communication_edge_worker_debut_confirmation_whatsapp") {
        return new Response(JSON.stringify({ ok: true, started: true }), { status: 200 });
      }
      if (rpc === "communication_edge_worker_terminer_confirmation_whatsapp") {
        const args = JSON.parse(options.body);
        assert.equal(args.p_resultat, "accepte");
        assert.equal(args.p_message_id, "wamid.synthetic-c73-worker");
        assert.equal(args.p_code_erreur, null);
        return new Response(JSON.stringify({ ok: true, recorded: true, status: "envoye" }), { status: 200 });
      }
      throw new Error(`unexpected RPC: ${rpc}`);
    }
  });

  const result = await adapters.processWhatsappConfirmations({ limit: 3 });
  assert.deepEqual(result, {
    ok: true, attempted: 1, accepted: 1, definitive: 0,
    retryScheduled: 0, uncertain: 0, recovered: 0
  });
  assert.deepEqual(calls, [
    "communication_edge_worker_recuperer_confirmations_whatsapp",
    "communication_edge_worker_reserver_confirmation_whatsapp",
    "communication_edge_worker_contexte_confirmation_whatsapp",
    "communication_edge_worker_code_whatsapp_pour_envoi",
    "communication_edge_worker_debut_confirmation_whatsapp",
    "meta_simule",
    "communication_edge_worker_terminer_confirmation_whatsapp",
    "communication_edge_worker_reserver_confirmation_whatsapp"
  ]);
  assert.equal(providerRequest.body.template.components[0].parameters[0].text, "654321");
  const summary = JSON.stringify(result);
  assert.equal(summary.includes("654321"), false);
  assert.equal(summary.includes("18095550123"), false);
  assert.equal(summary.includes("wamid.synthetic-c73-worker"), false);
  assert.equal(providerRequest.options.headers["idempotency-key"], undefined);
});

test("une configuration de modèle absente laisse les demandes en attente sans appel fournisseur", async () => {
  const calls = [];
  const adapters = createWorkerAdapters({
    env: rpcEnv("communication_worker"),
    now: () => now,
    fetchImpl: async url => {
      const rpc = new URL(String(url)).pathname.split("/").at(-1);
      calls.push(rpc);
      if (rpc === "communication_edge_worker_recuperer_confirmations_whatsapp") {
        return new Response(JSON.stringify({ ok: true, recovered: 0 }), { status: 200 });
      }
      throw new Error("unexpected unconfigured claim");
    }
  });
  assert.deepEqual(await adapters.processWhatsappConfirmations({ limit: 4 }), {
    ok: true, attempted: 0, recovered: 0, blocked: true
  });
  assert.deepEqual(calls, ["communication_edge_worker_recuperer_confirmations_whatsapp"]);
});

test("le worker n'appelle aucun adaptateur sans jeton ou si le raccordement SQL manque", async () => {
  let calls = 0;
  const unavailable = createWorkerHandler({ env: env() });
  const request = () => new Request("https://edge.test/communication-worker", {
    method: "POST", headers: { authorization: `Bearer ${workerToken}` }, body: "{}"
  });
  assert.equal((await unavailable(request())).status, 503);

  const protectedHandler = createWorkerHandler({
    env: env(),
    processPrioritizedP08: async () => { calls += 1; return { ok: true, prioritaire_en_attente: 0 }; },
    processTransactionalOutbox: async () => ({ processed: 0 }),
    reconcileExpo: async () => ({ checked: 0 }),
    processWhatsappConfirmations: async () => ({ attempted: 0 })
  });
  const denied = await protectedHandler(new Request("https://edge.test/communication-worker", { method: "POST", body: "{}" }));
  assert.equal(denied.status, 401);
  assert.equal(calls, 0);
});
