import { createExpoReceiptHandler } from "../_shared/expo-receipts.mjs";

// Endpoint interne : le jeton de déclenchement est vérifié avant tout appel à Expo.
Deno.serve(createExpoReceiptHandler({ env: name => Deno.env.get(name) ?? "" }));
