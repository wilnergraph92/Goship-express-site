import { createWebhookHandler } from "../_shared/webhook-adapters.mjs";

// Les fournisseurs n'émettent pas de JWT Supabase. L'authentification Meta,
// Brevo ou Resend est donc vérifiée dans le gestionnaire avant tout RPC métier.
Deno.serve(createWebhookHandler({ env: name => Deno.env.get(name) ?? "" }));
