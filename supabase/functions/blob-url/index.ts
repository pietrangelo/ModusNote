// Supabase Edge Function entry point: wires the handler to the deployment's
// secrets (`supabase secrets set R2_ACCOUNT_ID=... R2_BUCKET=...
// R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=...`). SUPABASE_URL and
// SUPABASE_ANON_KEY are provided by the platform.

import { makeHandler } from "./handler.ts";

declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (request: Request) => Promise<Response>): void;
};

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing setting ${name}`);
  return value;
}

const supabaseUrl = required("SUPABASE_URL");
const anonKey = required("SUPABASE_ANON_KEY");

// Asks the database as the caller, so the answer comes from the same
// security-definer helper the RLS policies use.
async function authorize(token: string, workspace: string): Promise<boolean> {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/is_workspace_account`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ workspace }),
  });
  if (response.status === 401 || response.status === 403) return false;
  if (!response.ok) throw new Error("authorization unavailable");
  return (await response.json()) === true;
}

Deno.serve(
  makeHandler({
    allowedOrigin: Deno.env.get("APP_ORIGIN") ?? "https://modus.serv.run",
    r2: {
      accountId: required("R2_ACCOUNT_ID"),
      bucket: required("R2_BUCKET"),
      accessKeyId: required("R2_ACCESS_KEY_ID"),
      secretAccessKey: required("R2_SECRET_ACCESS_KEY"),
    },
    expiresSeconds: 300,
    now: () => new Date(),
    authorize,
  }),
);
