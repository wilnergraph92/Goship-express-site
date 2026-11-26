import { createWorkerAdapters } from "../_shared/worker-adapters.mjs";
import { createWorkerHandler } from "../_shared/worker-orchestrator.mjs";

// Le déclencheur reste authentifié par un jeton distinct. Les identifiants RPC
// doivent être fournis par une décision S-1 ; cette fonction ne les crée pas.
const env = (name: string) => Deno.env.get(name) ?? "";
Deno.serve(createWorkerHandler({ env, ...createWorkerAdapters({ env }) }));
