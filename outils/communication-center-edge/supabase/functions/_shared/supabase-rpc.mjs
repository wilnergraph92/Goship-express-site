import {
  COMMUNICATION_RPC_ALLOWLIST,
  createCommunicationJwtSigner
} from "./communication-jwt.mjs";

function readEnv(env, name) {
  return typeof env === "function" ? env(name) ?? "" : env?.[name] ?? "";
}

function publishableKey(env) {
  const keys = readEnv(env, "SUPABASE_PUBLISHABLE_KEYS");
  if (keys) {
    try {
      const parsed = JSON.parse(keys);
      if (parsed && typeof parsed.default === "string") return parsed.default;
    } catch {
      return "";
    }
  }
  return readEnv(env, "SUPABASE_PUBLISHABLE_KEY") || readEnv(env, "SUPABASE_ANON_KEY");
}

function apiBase(env) {
  let value;
  try { value = new URL(readEnv(env, "SUPABASE_URL")); } catch { return null; }
  if (value.protocol !== "https:" && !(value.protocol === "http:" &&
      ["localhost", "127.0.0.1", "::1"].includes(value.hostname))) return null;
  value.pathname = `${value.pathname.replace(/\/$/, "")}/rest/v1/rpc/`;
  value.search = "";
  value.hash = "";
  return value;
}

export class SupabaseRpcFailure extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

/**
 * Creates a PostgREST client bound to one technical role and its fixed RPC list.
 * The Supabase API key identifies the project; the short-lived ES256 JWT supplies
 * the restricted Postgres role. service_role is never accepted as a fallback.
 */
export function createSupabaseRpcClient({
  env = {},
  fetchImpl = fetch,
  expectedRole,
  cryptoImpl = globalThis.crypto,
  now = Date.now
} = {}) {
  const allowedNames = COMMUNICATION_RPC_ALLOWLIST[expectedRole];
  const allowed = allowedNames ? new Set(allowedNames) : null;
  const signJwt = createCommunicationJwtSigner({ env, cryptoImpl, now });

  return async function callRpc(name, args) {
    if (!/^[a-z][a-z0-9_]{1,100}$/.test(String(name))) {
      throw new SupabaseRpcFailure("RPC_NAME_INVALID");
    }
    if (!allowed || !allowed.has(name) || expectedRole === "service_role") {
      throw new SupabaseRpcFailure("RPC_NOT_ALLOWED");
    }
    const base = apiBase(env);
    const apiKey = publishableKey(env);
    if (!base || !apiKey) throw new SupabaseRpcFailure("RPC_CONFIGURATION_INVALID");

    let token;
    try {
      token = await signJwt(expectedRole);
    } catch {
      throw new SupabaseRpcFailure("RPC_CONFIGURATION_INVALID");
    }

    const endpoint = new URL(encodeURIComponent(name), base);
    let response;
    try {
      response = await fetchImpl(endpoint, {
        method: "POST",
        redirect: "error",
        headers: {
          apikey: apiKey,
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          "content-profile": "communication_edge",
          accept: "application/json"
        },
        body: JSON.stringify(args ?? {})
      });
    } catch {
      throw new SupabaseRpcFailure("RPC_UNAVAILABLE");
    }
    if (response.status === 401 || response.status === 403) {
      throw new SupabaseRpcFailure("RPC_AUTHORIZATION_FAILED");
    }
    if (!response.ok) throw new SupabaseRpcFailure("RPC_UNAVAILABLE");
    try {
      return await response.json();
    } catch {
      throw new SupabaseRpcFailure("RPC_RESPONSE_INVALID");
    }
  };
}
