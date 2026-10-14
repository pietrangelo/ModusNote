// Issues presigned R2 URLs for encrypted blobs, and deletes and lists them
// itself. R2 credentials stay here; the client only ever receives a URL
// for one object, valid for minutes, or the ids of its workspace's
// objects, after the database confirms its account belongs to the
// workspace.
//
// Responses carry fixed messages only: nothing from the request, the
// database or the credentials is echoed back.

import { presignUrl, r2BucketUrl, r2ObjectUrl, signRequest } from "./presign.ts";

export interface HandlerConfig {
  allowedOrigin: string;
  r2: { accountId: string; bucket: string; accessKeyId: string; secretAccessKey: string };
  expiresSeconds: number;
  now: () => Date;
  // True when the token's account belongs to the workspace; throws when
  // the database cannot be asked.
  authorize: (token: string, workspace: string) => Promise<boolean>;
  // How the function reaches R2 for deleting and listing; the global
  // fetch when absent.
  r2Fetch?: (
    url: string,
    init: { method: string; headers: Record<string, string> },
  ) => Promise<Response>;
}

const workspacePattern = /^[0-9a-f]{32}$/;
// The BlobId alphabet of the domain: no separators, so no path traversal.
const blobPattern = /^[A-Za-z0-9_-]{1,128}$/;
// Continuation tokens are R2's: opaque, but printable and bounded.
const cursorPattern = /^[\x21-\x7e]{1,1024}$/;
const timestampPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$/;
const maxDeletions = 50;
// A full batch of the longest blob ids, and nothing much bigger.
const maxBodyBytes = 8192;

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
  const objectOf = (workspace: string, blob: string) =>
    r2ObjectUrl(config.r2.accountId, config.r2.bucket, workspace, blob);
  const sign = (
    method: string,
    { host, path }: { host: string; path: string },
    signedHeaders: Record<string, string>,
  ) =>
    presignUrl({
      method,
      host,
      path,
      region: "auto",
      service: "s3",
      accessKeyId: config.r2.accessKeyId,
      secretAccessKey: config.r2.secretAccessKey,
      date: config.now(),
      expiresSeconds: config.expiresSeconds,
      signedHeaders,
    });
  // A request the function makes itself, signed in its headers.
  const callR2 = async (
    method: string,
    { host, path }: { host: string; path: string },
    query?: Record<string, string>,
  ) => {
    const signed = await signRequest({
      method,
      host,
      path,
      query,
      region: "auto",
      service: "s3",
      accessKeyId: config.r2.accessKeyId,
      secretAccessKey: config.r2.secretAccessKey,
      date: config.now(),
    });
    return fetchR2(signed.url, { method, headers: signed.headers });
  };

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
    if (text.length > maxBodyBytes) return refuse(request, 400, "malformed request");
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return refuse(request, 400, "malformed request");
    }
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return refuse(request, 400, "malformed request");
    }
    const action = parseAction(body as Record<string, unknown>);
    if (!action) return refuse(request, 400, "malformed request");
    const { workspace } = action;

    let member: boolean;
    try {
      member = await config.authorize(token, workspace);
    } catch {
      return refuse(request, 503, "authorization unavailable");
    }
    if (!member) return refuse(request, 403, "not a workspace account");

    switch (action.method) {
      case "GET":
      case "PUT": {
        // Blobs are written once under a random id: a PUT may only create,
        // so a member cannot replace someone else's recording.
        const headers: Record<string, string> =
          action.method === "PUT" ? { "If-None-Match": "*" } : {};
        const url = await sign(action.method, objectOf(workspace, action.blob), headers);
        return reply(request, 200, {
          url,
          method: action.method,
          headers,
          expires_in: config.expiresSeconds,
        });
      }
      case "DELETE": {
        // Deleted here, never through a URL handed out: R2 sees only this
        // function, and a member can delete only under its workspace.
        // A failed signature counts as R2 failing.
        const results = await Promise.allSettled(
          action.blobs.map(async (blob) => {
            const response = await callR2("DELETE", objectOf(workspace, blob));
            await response.body?.cancel();
            // 404: already gone, which is what was asked.
            if (!response.ok && response.status !== 404) throw new Error("storage refused");
          }),
        );
        if (results.some((result) => result.status === "rejected")) {
          return refuse(request, 503, "storage unavailable");
        }
        return reply(request, 200, { deleted: action.blobs.length });
      }
      case "LIST": {
        const query: Record<string, string> = {
          "list-type": "2",
          prefix: `${workspace}/`,
          "max-keys": "1000",
        };
        if (action.cursor) query["continuation-token"] = action.cursor;
        let xml: string;
        try {
          const response = await callR2(
            "GET",
            r2BucketUrl(config.r2.accountId, config.r2.bucket),
            query,
          );
          if (!response.ok) {
            await response.body?.cancel();
            return refuse(request, 503, "storage unavailable");
          }
          xml = await response.text();
        } catch {
          return refuse(request, 503, "storage unavailable");
        }
        return reply(request, 200, parseListing(xml, workspace));
      }
    }
  };
}

type Action =
  | { method: "GET" | "PUT"; workspace: string; blob: string }
  | { method: "DELETE"; workspace: string; blobs: string[] }
  | { method: "LIST"; workspace: string; cursor: string | null };

// Every field is checked against its alphabet before anything is asked
// of the database or of R2.
function parseAction(body: Record<string, unknown>): Action | null {
  const { workspace_id: workspace, method } = body;
  if (typeof workspace !== "string" || !workspacePattern.test(workspace)) return null;
  switch (method) {
    case "GET":
    case "PUT": {
      const blob = body.blob_id;
      if (typeof blob !== "string" || !blobPattern.test(blob)) return null;
      return { method, workspace, blob };
    }
    case "DELETE": {
      const blobs = body.blob_ids;
      if (!Array.isArray(blobs) || blobs.length === 0 || blobs.length > maxDeletions) return null;
      if (!blobs.every((blob) => typeof blob === "string" && blobPattern.test(blob))) return null;
      return { method, workspace, blobs: [...new Set(blobs as string[])] };
    }
    case "LIST": {
      const cursor = body.cursor ?? null;
      if (cursor !== null && (typeof cursor !== "string" || !cursorPattern.test(cursor))) return null;
      return { method, workspace, cursor };
    }
    default:
      return null;
  }
}

export interface ListedBlob {
  id: string;
  size: number;
  stored_at: string;
}

// ListObjectsV2 output, read without an XML parser: only keys of the form
// `<workspace>/<blob>.enc` with a plain size and timestamp are kept, so
// nothing of another workspace, no entity and no odd name gets through.
export function parseListing(xml: string, workspace: string): { blobs: ListedBlob[]; cursor: string | null } {
  const blobs: ListedBlob[] = [];
  for (const [, entry] of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
    const key = /<Key>([^<]*)<\/Key>/.exec(entry)?.[1];
    const modified = /<LastModified>([^<]*)<\/LastModified>/.exec(entry)?.[1];
    const size = /<Size>([^<]*)<\/Size>/.exec(entry)?.[1];
    if (key === undefined || modified === undefined || size === undefined) continue;
    if (!key.startsWith(`${workspace}/`) || !key.endsWith(".enc")) continue;
    const id = key.slice(workspace.length + 1, -".enc".length);
    if (!blobPattern.test(id) || !/^\d{1,15}$/.test(size)) continue;
    if (!timestampPattern.test(modified) || Number.isNaN(Date.parse(modified))) continue;
    blobs.push({ id, size: Number(size), stored_at: new Date(modified).toISOString() });
  }
  const truncated = /<IsTruncated>true<\/IsTruncated>/.test(xml);
  const next = /<NextContinuationToken>([^<]*)<\/NextContinuationToken>/.exec(xml)?.[1];
  return { blobs, cursor: truncated && next && cursorPattern.test(next) ? next : null };
}
