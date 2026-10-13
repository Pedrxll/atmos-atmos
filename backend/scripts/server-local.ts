import { createHandler } from "../../supabase/functions/finance-api/handler.ts";
const url = Deno.env.get("SUPABASE_URL") ?? "";
if (url !== "http://127.0.0.1:55321") throw new Error("Local runtime only");
Deno.serve(
  { hostname: "127.0.0.1", port: 55280 },
  createHandler({
    supabaseUrl: url,
    anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    allowedOrigins: ["http://127.0.0.1:4319"],
  }),
);
