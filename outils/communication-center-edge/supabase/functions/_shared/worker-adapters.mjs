import { reconcileExpoReceipts } from "./expo-receipts.mjs";
import { createSupabaseRpcClient } from "./supabase-rpc.mjs";
import { createWhatsappConfirmationSender } from "./whatsapp-template-adapter.mjs";

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function createWorkerAdapters({ env = {}, fetchImpl = fetch, now = Date.now, cryptoImpl = globalThis.crypto } = {}) {
  const callRpc = createSupabaseRpcClient({
    env,
    fetchImpl,
    expectedRole: "communication_worker",
    now
  });
  const whatsappSender = createWhatsappConfirmationSender({ env, fetchImpl });

  return {
    async processPrioritizedP08({ limit }) {
      const result = await callRpc("communication_edge_worker_traiter_evenements_prioritaires", { p_limite: limit });
      if (!object(result) || result.ok !== true || !Number.isInteger(result.prioritaire_en_attente)) {
        throw new Error("P08_RPC_RESPONSE_INVALID");
      }
      return result;
    },

    async reconcileExpo({ limit }) {
      const listed = await callRpc("communication_edge_worker_expo_recus_a_reconcilier", { p_limite: limit });
      if (!object(listed) || !Array.isArray(listed.tickets)) throw new Error("EXPO_TICKET_LIST_INVALID");
      if (listed.tickets.length === 0) return { ok: true, reconciled: 0, updated: 0 };

      const results = await reconcileExpoReceipts(listed.tickets, { fetchImpl, now });
      const saved = await callRpc("communication_edge_worker_expo_enregistrer_recus", { p_resultats: results });
      if (!object(saved) || saved.ok !== true || !Number.isInteger(saved.mis_a_jour)) {
        throw new Error("EXPO_RECEIPT_PERSISTENCE_UNCONFIRMED");
      }
      return { ok: true, reconciled: results.length, updated: saved.mis_a_jour };
    },

    async processTransactionalOutbox({ limit }) {
      const result = await callRpc("communication_edge_worker_traiter_notifications", { p_limite: limit });
      if (!object(result)) throw new Error("TRANSACTIONAL_WORKER_RESPONSE_INVALID");
      return result;
    },

    async processWhatsappConfirmations({ limit }) {
      const boundedLimit = Number.isInteger(limit) ? Math.min(Math.max(limit, 1), 50) : 50;
      const recovered = await callRpc("communication_edge_worker_recuperer_confirmations_whatsapp", {
        p_limite: boundedLimit
      });
      if (!object(recovered) || recovered.ok !== true || !Number.isInteger(recovered.recovered)) {
        throw new Error("WHATSAPP_CONFIRMATION_RECOVERY_INVALID");
      }
      if (!whatsappSender.isConfigured()) {
        return { ok: true, attempted: 0, recovered: recovered.recovered, blocked: true };
      }

      const totals = {
        ok: true,
        attempted: 0,
        accepted: 0,
        definitive: 0,
        retryScheduled: 0,
        uncertain: 0,
        recovered: recovered.recovered
      };
      for (let index = 0; index < boundedLimit; index += 1) {
        if (!cryptoImpl?.randomUUID) throw new Error("WHATSAPP_CONFIRMATION_CLAIM_UNAVAILABLE");
        const claimId = cryptoImpl.randomUUID();
        const claim = await callRpc("communication_edge_worker_reserver_confirmation_whatsapp", {
          p_claim_id: claimId
        });
        if (!object(claim) || claim.ok !== true || typeof claim.claimed !== "boolean") {
          throw new Error("WHATSAPP_CONFIRMATION_CLAIM_INVALID");
        }
        if (!claim.claimed) break;
        if (!Number.isSafeInteger(claim.envoi_id) || claim.envoi_id < 1 || claim.claim_id !== claimId ||
            typeof claim.expire_le !== "string" || !Number.isFinite(Date.parse(claim.expire_le))) {
          throw new Error("WHATSAPP_CONFIRMATION_CLAIM_INVALID");
        }

        const envoiId = claim.envoi_id;
        const context = await callRpc("communication_edge_worker_contexte_confirmation_whatsapp", {
          p_envoi_id: envoiId,
          p_claim_id: claimId
        });
        if (!object(context) || typeof context.destinataire !== "string" ||
            !/^\+?[0-9]{5,20}$/.test(context.destinataire) ||
            !["fr", "en", "es", "ht"].includes(context.langue)) {
          continue;
        }

        const code = await callRpc("communication_edge_worker_code_whatsapp_pour_envoi", {
          p_envoi_id: envoiId,
          p_claim_id: claimId
        });
        if (code !== null && (typeof code !== "string" || !/^[0-9]{6}$/.test(code))) {
          throw new Error("WHATSAPP_CONFIRMATION_CODE_INVALID");
        }
        if (!code) continue;
        const started = await callRpc("communication_edge_worker_debut_confirmation_whatsapp", {
          p_envoi_id: envoiId,
          p_claim_id: claimId
        });
        if (!object(started) || started.ok !== true || typeof started.started !== "boolean") {
          throw new Error("WHATSAPP_CONFIRMATION_START_INVALID");
        }
        if (!started.started) continue;

        totals.attempted += 1;
        let delivery;
        try {
          delivery = await whatsappSender.send({
            destination: context.destinataire,
            language: context.langue,
            code
          });
        } catch {
          delivery = { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
        }
        if (!object(delivery) ||
            !["accepte", "definitif", "temporaire", "incertain"].includes(delivery.outcome)) {
          delivery = { outcome: "incertain", errorCode: "RESULTAT_INCERTAIN" };
        }

        const recorded = await callRpc("communication_edge_worker_terminer_confirmation_whatsapp", {
          p_envoi_id: envoiId,
          p_claim_id: claimId,
          p_resultat: delivery.outcome,
          p_message_id: delivery.outcome === "accepte" ? delivery.messageId : null,
          p_code_erreur: delivery.errorCode ?? null
        });
        if (!object(recorded) || recorded.ok !== true || recorded.recorded !== true) {
          throw new Error("WHATSAPP_CONFIRMATION_RESULT_UNCONFIRMED");
        }
        if (delivery.outcome === "accepte") totals.accepted += 1;
        else if (delivery.outcome === "definitif") totals.definitive += 1;
        else if (delivery.outcome === "temporaire" && recorded.status === "confirmation") totals.retryScheduled += 1;
        else totals.uncertain += 1;
      }
      return totals;
    },

    async claimWhatsappConfirmation({ claimId = null } = {}) {
      if (!cryptoImpl?.randomUUID) {
        throw new Error("WHATSAPP_CONFIRMATION_TASK_INVALID");
      }
      const claim = claimId ?? cryptoImpl.randomUUID();
      if (typeof claim !== "string" ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(claim)) {
        throw new Error("WHATSAPP_CONFIRMATION_TASK_INVALID");
      }
      const result = await callRpc("communication_edge_worker_reserver_confirmation_whatsapp", {
        p_claim_id: claim
      });
      if (!object(result) || result.ok !== true || typeof result.claimed !== "boolean") {
        throw new Error("WHATSAPP_CONFIRMATION_CLAIM_INVALID");
      }
      if (!result.claimed) return { claimed: false };
      if (!Number.isSafeInteger(result.envoi_id) || result.envoi_id < 1 || result.claim_id !== claim ||
          typeof result.expire_le !== "string") {
        throw new Error("WHATSAPP_CONFIRMATION_CLAIM_INVALID");
      }
      return { claimed: true, envoiId: result.envoi_id, claimId: claim, expiresAt: result.expire_le };
    },

    async retrieveWhatsappConfirmationCode({ envoiId, claimId }) {
      if (!Number.isSafeInteger(envoiId) || envoiId < 1 || typeof claimId !== "string" ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(claimId)) {
        throw new Error("WHATSAPP_CONFIRMATION_TASK_INVALID");
      }
      const code = await callRpc("communication_edge_worker_code_whatsapp_pour_envoi", {
        p_envoi_id: envoiId,
        p_claim_id: claimId
      });
      if (code === null) return null;
      if (typeof code !== "string" || !/^[0-9]{6}$/.test(code)) {
        throw new Error("WHATSAPP_CONFIRMATION_CODE_INVALID");
      }
      return code;
    }
  };
}
