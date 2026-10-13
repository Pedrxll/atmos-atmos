import { authorizeAdminRequest } from "../_shared/adminModuleAuth.ts";
// deno-lint-ignore no-import-prefix -- Preserve the existing Supabase SDK endpoint import.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createEnrichmentHandler } from "./handler.ts";
Deno.serve(createEnrichmentHandler({
  apiKey: Deno.env.get("LOVABLE_API_KEY"),
  authorize: (request) =>
    authorizeAdminRequest(request, {
      createClient,
      supabaseUrl: Deno.env.get("SUPABASE_URL"),
      anonKey: Deno.env.get("SUPABASE_ANON_KEY"),
      modules: ["cadastros", "b2b", "b2c"],
    }),
}));
