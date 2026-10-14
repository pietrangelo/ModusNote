// Supabase Edge Function entry point. Uses the same R2 secrets as blob-url
// (`supabase secrets set` once for the project); SUPABASE_URL and
// SUPABASE_ANON_KEY are provided by the platform. The service key is never
// needed: the database is asked as the caller.

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

// A list of workspace ids from an RPC run as the caller, or null when the
// token is refused.
async function rpc(name: string, token: string): Promise<string[] | null> {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (response.status === 401 || response.status === 403) {
    await response.body?.cancel();
    return null;
  }
  if (!response.ok) throw new Error("database unavailable");
  const body: unknown = await response.json();
  if (!Array.isArray(body) || !body.every((id) => typeof id === "string")) {
    throw new Error("database unavailable");
  }
  return body;
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
    now: () => new Date(),
    database: {
      soleWorkspaces: (token) => rpc("sole_workspaces", token),
      deleteAccount: (token) => rpc("delete_account", token),
    },
  }),
);
