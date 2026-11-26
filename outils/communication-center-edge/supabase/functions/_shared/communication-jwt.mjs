const ROLES = new Set(["communication_webhook", "communication_worker"]);
const ROLE_TTL_ENV = Object.freeze({
  communication_webhook: "COMMUNICATION_WEBHOOK_JWT_TTL",
  communication_worker: "COMMUNICATION_WORKER_JWT_TTL"
});

function readEnv(env, name) {
  return typeof env === "function" ? env(name) ?? "" : env?.[name] ?? "";
}

function invalidConfiguration() {
  return new Error("JWT_CONFIGURATION_INVALID");
}

function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function encodeJson(value) {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function integerSetting(value, minimum = 1) {
  if (typeof value !== "string" || !/^[0-9]+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= minimum ? parsed : null;
}

function privateJwkFor(env, kid) {
  let keys;
  try {
    keys = JSON.parse(readEnv(env, "COMMUNICATION_JWT_PRIVATE_KEYS"));
  } catch {
    throw invalidConfiguration();
  }
  if (!Array.isArray(keys) || keys.length === 0) throw invalidConfiguration();
  const matches = keys.filter(key => key && key.kid === kid);
  if (matches.length !== 1) throw invalidConfiguration();
  const jwk = matches[0];
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || jwk.alg !== "ES256" ||
      typeof jwk.d !== "string" || typeof jwk.x !== "string" || typeof jwk.y !== "string" ||
      (Array.isArray(jwk.key_ops) && !jwk.key_ops.includes("sign"))) {
    throw invalidConfiguration();
  }
  return jwk;
}

/**
 * Creates short-lived ES256 tokens for exactly one of the two database roles.
 * The private JWK must correspond to a public key explicitly trusted by the
 * Supabase/PostgREST verifier. No signing material is logged or returned.
 */
export function createCommunicationJwtSigner({ env = {}, cryptoImpl = globalThis.crypto, now = Date.now } = {}) {
  return async function signCommunicationJwt(role) {
    if (!ROLES.has(role) || role === "service_role" || !cryptoImpl?.subtle ||
        typeof cryptoImpl.getRandomValues !== "function") {
      throw invalidConfiguration();
    }

    const issuer = readEnv(env, "COMMUNICATION_JWT_ISSUER");
    const audience = readEnv(env, "COMMUNICATION_JWT_AUDIENCE");
    const kid = readEnv(env, "COMMUNICATION_JWT_ACTIVE_KID");
    const maxTtl = integerSetting(readEnv(env, "COMMUNICATION_JWT_MAX_TTL_SECONDS"));
    const ttl = integerSetting(readEnv(env, ROLE_TTL_ENV[role]));
    if (!issuer || !audience || !kid || !maxTtl || !ttl || ttl > maxTtl) {
      throw invalidConfiguration();
    }

    const jwk = privateJwkFor(env, kid);
    let privateKey;
    try {
      privateKey = await cryptoImpl.subtle.importKey(
        "jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
      );
    } catch {
      throw invalidConfiguration();
    }

    const issuedAt = Math.floor(now() / 1000);
    const nonce = new Uint8Array(16);
    cryptoImpl.getRandomValues(nonce);
    const header = { alg: "ES256", typ: "JWT", kid };
    const claims = {
      iss: issuer,
      aud: audience,
      role,
      iat: issuedAt,
      nbf: issuedAt,
      exp: issuedAt + ttl,
      jti: base64Url(nonce)
    };
    const signingInput = `${encodeJson(header)}.${encodeJson(claims)}`;
    let signature;
    try {
      signature = new Uint8Array(await cryptoImpl.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(signingInput)
      ));
    } catch {
      throw invalidConfiguration();
    }
    // ES256 JWT signatures are the fixed-width IEEE-P1363 r || s form.
    if (signature.byteLength !== 64) throw invalidConfiguration();
    return `${signingInput}.${base64Url(signature)}`;
  };
}

export const COMMUNICATION_RPC_ALLOWLIST = Object.freeze({
  communication_webhook: Object.freeze([
    "communication_edge_webhook_recevoir_statut_transactionnel",
    "communication_edge_webhook_recevoir_evenement"
  ]),
  communication_worker: Object.freeze([
    "communication_edge_worker_traiter_evenements_prioritaires",
    "communication_edge_worker_expo_recus_a_reconcilier",
    "communication_edge_worker_expo_enregistrer_recus",
    "communication_edge_worker_traiter_notifications",
    "communication_edge_worker_recuperer_confirmations_whatsapp",
    "communication_edge_worker_reserver_confirmation_whatsapp",
    "communication_edge_worker_contexte_confirmation_whatsapp",
    "communication_edge_worker_code_whatsapp_pour_envoi",
    "communication_edge_worker_debut_confirmation_whatsapp",
    "communication_edge_worker_terminer_confirmation_whatsapp"
  ])
});
