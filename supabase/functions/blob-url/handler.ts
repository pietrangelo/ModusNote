// Issues presigned R2 URLs for encrypted blobs. R2 credentials stay here;
// the client only ever receives a URL for one object, valid for minutes,
// after the database confirms its account belongs to the workspace.
//
// Responses carry fixed messages only: nothing from the request, the
// database or the credentials is echoed back.

import { presignUrl, r2ObjectUrl } from "./presign.ts";

export interface HandlerConfig {
  allowedOrigin: string;
  r2: { accountId: string; bucket: string; accessKeyId: string; secretAccessKey: string };
  expiresSeconds: number;
  now: () => Date;
  // True when the token's account belongs to the workspace; throws when
  // the database cannot be asked.
  authorize: (token: string, workspace: string) => Promise<boolean>;
}

const workspacePattern = /^[0-9a-f]{32}$/;
// The BlobId alphabet of the domain: no separators, so no path traversal.
const blobPattern = /^[A-Za-z0-9_-]{1,128}$/;
const maxBodyBytes = 1024;

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
    const { workspace_id: workspace, blob_id: blob, method } = body as Record<string, unknown>;
    if (
      typeof workspace !== "string" ||
      !workspacePattern.test(workspace) ||
      typeof blob !== "string" ||
      !blobPattern.test(blob) ||
      (method !== "GET" && method !== "PUT")
    ) {
      return refuse(request, 400, "malformed request");
    }

    let member: boolean;
    try {
      member = await config.authorize(token, workspace);
    } catch {
      return refuse(request, 503, "authorization unavailable");
    }
    if (!member) return refuse(request, 403, "not a workspace account");

    // Blobs are written once under a random id: a PUT may only create, so
    // a member cannot replace someone else's recording.
    const headers: Record<string, string> = method === "PUT" ? { "If-None-Match": "*" } : {};
    const { host, path } = r2ObjectUrl(config.r2.accountId, config.r2.bucket, workspace, blob);
    const url = await presignUrl({
      method,
      host,
      path,
      region: "auto",
      service: "s3",
      accessKeyId: config.r2.accessKeyId,
      secretAccessKey: config.r2.secretAccessKey,
      date: config.now(),
      expiresSeconds: config.expiresSeconds,
      signedHeaders: headers,
    });
    return reply(request, 200, { url, method, headers, expires_in: config.expiresSeconds });
  };
}
