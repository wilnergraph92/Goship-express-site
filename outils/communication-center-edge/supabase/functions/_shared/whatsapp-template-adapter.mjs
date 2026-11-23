const PHONE_PATTERN = /^\+?[0-9]{5,20}$/;
const TEMPLATE_PATTERN = /^[a-z0-9_]{1,512}$/;
const MESSAGE_ID_PATTERN = /^[A-Za-z0-9_.:-]{1,200}$/;
const MAX_RESPONSE_BYTES = 8_192;
const TEMPORARY_META_ERROR_CODES = new Set([1, 2, 4, 17, 80007, 130429, 131000, 131016, 131056, 133004]);
const META_RATE_LIMIT_ERROR_CODES = new Set([4, 17, 80007, 130429, 131056]);

function readEnv(env, name) {
  return typeof env === "function" ? env(name) ?? "" : env?.[name] ?? "";
}

function configuration(env) {
  const accessToken = readEnv(env, "META_WHATSAPP_ACCESS_TOKEN");
  const phoneNumberId = readEnv(env, "META_WHATSAPP_PHONE_NUMBER_ID");
  const apiVersion = readEnv(env, "META_WHATSAPP_API_VERSION");
  const templateName = readEnv(env, "META_WHATSAPP_CONFIRMATION_TEMPLATE");
  if (!accessToken || !/^[0-9]{5,32}$/.test(phoneNumberId) ||
      !/^v[0-9]{1,3}\.0$/.test(apiVersion) || !TEMPLATE_PATTERN.test(templateName)) return null;
  return { accessToken, phoneNumberId, apiVersion, templateName };
}

function languageCode(language) {
  if (language === "en") return "en_US";
  if (language === "es") return "es";
  // Le sender GoShip existant utilise le modèle français comme repli pour ht.
  if (language === "fr" || language === "ht") return "fr";
  return null;
}

async function readBoundedJson(response) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > MAX_RESPONSE_BYTES) return null;
  if (!response.body) return null;
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_RESPONSE_BYTES) {
        await reader.cancel();
        return null;
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
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return null;
  }
}

/** Envoie un seul modèle Meta et ne conserve ni ne journalise le code. */
export function createWhatsappConfirmationSender({
  env = {},
  fetchImpl = fetch,
  timeoutMs = 15_000
} = {}) {
  const currentConfiguration = () => configuration(env);

  return {
    isConfigured() {
      return currentConfiguration() !== null;
    },

    async send({ destination, language, code }) {
      const config = currentConfiguration();
      const locale = languageCode(language);
      if (!config || !PHONE_PATTERN.test(destination ?? "") || !locale || !/^[0-9]{6}$/.test(code ?? "")) {
        return { outcome: "definitif", errorCode: "MODELE_INDISPONIBLE" };
      }

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const endpoint = `https://graph.facebook.com/${config.apiVersion}/${config.phoneNumberId}/messages`;
        const response = await fetchImpl(endpoint, {
          method: "POST",
          redirect: "error",
          signal: controller.signal,
          headers: {
            authorization: `Bearer ${config.accessToken}`,
            "content-type": "application/json"
          },
          body: JSON.stringify({
            messaging_product: "whatsapp",
            to: destination,
            type: "template",
            template: {
              name: config.templateName,
              language: { code: locale },
              components: [{
                type: "body",
                parameters: [{ type: "text", text: code }]
              }]
            }
          })
        });
        if (response.status === 408 || response.status === 425 || response.status >= 500) {
          return { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
        }
        if (response.status >= 400) {
          const payload = await readBoundedJson(response);
          const metaCode = payload?.error?.code;
          if (Number.isSafeInteger(metaCode) && TEMPORARY_META_ERROR_CODES.has(metaCode)) {
            return {
              outcome: "temporaire",
              errorCode: META_RATE_LIMIT_ERROR_CODES.has(metaCode) ? "LIMITE_DEBIT" : "ERREUR_FOURNISSEUR"
            };
          }
          if (response.status === 429 && !Number.isSafeInteger(metaCode)) {
            return { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
          }
          return { outcome: "definitif", errorCode: "REFUS_FOURNISSEUR" };
        }
        if (!response.ok) {
          return { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
        }

        const payload = await readBoundedJson(response);
        const messageId = payload?.messages?.[0]?.id;
        if (typeof messageId !== "string" || !MESSAGE_ID_PATTERN.test(messageId)) {
          return { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
        }
        return { outcome: "accepte", messageId };
      } catch {
        return { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
      } finally {
        clearTimeout(timer);
      }
    }
  };
}
