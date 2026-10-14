// Deletes the caller's account, as Google Play requires of apps that create
// one: its email and sign-in (auth.users), its place in every workspace, its
// link rows, and every workspace it alone belongs to, with the ciphertext of
// those workspaces in the database and their encrypted blobs on R2.
//
// The database work is one call, made as the caller (delete_account), so it
// can never reach another account. The blobs are removed first, so a failure
// on R2 leaves the account whole and the request can be repeated; then once
// more for the workspaces the database actually deleted, for blobs uploaded
// in between. A workspace another account still belongs to keeps its rows
// and blobs: they are that account's notes too.
//
// Responses carry fixed messages only.

import { parseListing } from "../blob-url/handler.ts";
import { r2BucketUrl, r2ObjectUrl, signRequest } from "../blob-url/presign.ts";

export interface Database {
  // The workspaces the token's account alone belongs to; null when the
  // token is refused. Throws when the database cannot be asked.
  soleWorkspaces(token: string): Promise<string[] | null>;
  // Deletes the account; returns the workspaces deleted with it, or null
  // when the token is refused. Throws when the database cannot be asked.
  deleteAccount(token: string): Promise<string[] | null>;
}

export interface HandlerConfig {
  allowedOrigin: string;
  r2: { accountId: string; bucket: string; accessKeyId: string; secretAccessKey: string };
  now: () => Date;
  database: Database;
  r2Fetch?: (
    url: string,
    init: { method: string; headers: Record<string, string> },
  ) => Promise<Response>;
}

const workspacePattern = /^[0-9a-f]{32}$/;
// The one body accepted: a request cannot delete an account by accident.
const confirmation = JSON.stringify({ confirm: "delete-account" });
// As the app's sweep: a listing that never ends is R2 misbehaving.
const maxPages = 100;
const parallelDeletions = 50;

export function makeHandler(config: HandlerConfig): (request: Request) => Promise<Response> {
  const cors = (request: Request): Record<string, string> =>
    request.headers.get("Origin") === config.allowedOrigin
      ? { "Access-Control-Allow-Origin": config.allowedOrigin, Vary: "Origin" }
      : { Vary: "Origin" };
  const reply = (request: Request, status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors(request), "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  const refuse = (request: Request, status: number, message: string) =>
    reply(request, status, { error: message });

  const fetchR2 = config.r2Fetch ?? ((url, init) => fetch(url, init));
  const callR2 = async (
    method: string,
    { host, path }: { host: string; path: string },
    query?: Record<string, string>,
  ) => {
    const { r2 } = config;
    const signed = await signRequest({
      method,
      host,
      path,
      query,
      region: "auto",
      service: "s3",
      accessKeyId: r2.accessKeyId,
      secretAccessKey: r2.secretAccessKey,
      date: config.now(),
    });
    return fetchR2(signed.url, { method, headers: signed.headers });
  };

  // Every object under `<workspace>/`; throws on any failure of R2.
  const purge = async (workspace: string) => {
    const seen = new Set<string>();
    let cursor: string | null = null;
    for (let page = 0; page < maxPages; page++) {
      const query: Record<string, string> = {
        "list-type": "2",
        prefix: `${workspace}/`,
        "max-keys": "1000",
      };
      if (cursor) query["continuation-token"] = cursor;
      const response = await callR2(
        "GET",
        r2BucketUrl(config.r2.accountId, config.r2.bucket),
        query,
      );
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error("storage refused");
      }
      const listing = parseListing(await response.text(), workspace);
      const ids = listing.blobs.map((blob) => blob.id);
      for (let start = 0; start < ids.length; start += parallelDeletions) {
        await Promise.all(
          ids.slice(start, start + parallelDeletions).map(async (blob) => {
            const deleted = await callR2(
              "DELETE",
              r2ObjectUrl(config.r2.accountId, config.r2.bucket, workspace, blob),
            );
            await deleted.body?.cancel();
            if (!deleted.ok && deleted.status !== 404) throw new Error("storage refused");
          }),
        );
      }
      if (listing.cursor === null) return;
      if (seen.has(listing.cursor)) throw new Error("listing repeats");
      seen.add(listing.cursor);
      cursor = listing.cursor;
    }
    throw new Error("listing too long");
  };
  const wellFormed = (workspaces: string[]) =>
    workspaces.every((workspace) => workspacePattern.test(workspace));

  return async (request) => {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          ...cors(request),
          "Access-Control-Allow-Methods": "POST",
          "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
          "Access-Control-Max-Age": "600",
        },
      });
    }
    if (request.method !== "POST") return refuse(request, 405, "method not allowed");

    const token = /^Bearer (\S+)$/.exec(request.headers.get("Authorization") ?? "")?.[1];
    if (!token) return refuse(request, 401, "missing session");
    const text = await request.text();
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return refuse(request, 400, "malformed request");
    }
    if (JSON.stringify(body) !== confirmation) return refuse(request, 400, "malformed request");

    let sole: string[] | null;
    try {
      sole = await config.database.soleWorkspaces(token);
    } catch {
      return refuse(request, 503, "database unavailable");
    }
    if (sole === null) return refuse(request, 401, "session refused");
    if (!wellFormed(sole)) return refuse(request, 503, "database unavailable");

    try {
      for (const workspace of sole) await purge(workspace);
    } catch {
      // Nothing of the account is deleted yet: the client can try again.
      return refuse(request, 503, "storage unavailable");
    }

    let gone: string[] | null;
    try {
      gone = await config.database.deleteAccount(token);
    } catch {
      return refuse(request, 503, "database unavailable");
    }
    if (gone === null) return refuse(request, 401, "session refused");

    // The account is gone whatever happens here: what is left on R2 is
    // ciphertext no key can open any more.
    for (const workspace of gone) {
      if (!workspacePattern.test(workspace)) continue;
      try {
        await purge(workspace);
      } catch {
        // Already reported as deleted; see the comment above.
      }
    }
    return reply(request, 200, { deleted: true });
  };
}
