import { createHandler } from "./handler.ts";

const runtime = globalThis as unknown as {
  EdgeRuntime?: { waitUntil: (task: Promise<unknown>) => void };
};
Deno.serve(createHandler({
  background: (task) => runtime.EdgeRuntime?.waitUntil(task),
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
  allowedOrigins: (Deno.env.get("FINANCE_ALLOWED_ORIGINS") ?? "").split(",")
    .map((v) => v.trim()).filter(Boolean),
}));
