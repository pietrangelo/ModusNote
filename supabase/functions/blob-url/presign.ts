// AWS Signature Version 4 query presigning (what R2's S3 API accepts),
// written against WebCrypto so the function has no third-party imports.

export interface PresignRequest {
  method: string;
  host: string;
  path: string;
  region: string;
  service: string;
  accessKeyId: string;
  secretAccessKey: string;
  date: Date;
  expiresSeconds: number;
  // Headers the caller must send unchanged, or the signature fails.
  signedHeaders?: Record<string, string>;
}

const encoder = new TextEncoder();

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

async function hmac(key: BufferSource, text: string): Promise<ArrayBuffer> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(text));
}

// RFC 3986 encoding as SigV4 defines it: only unreserved characters stay.
function uriEncode(text: string, keepSlash = false): string {
  return [...encoder.encode(text)]
    .map((byte) => {
      const char = String.fromCharCode(byte);
      if (/[A-Za-z0-9\-_.~]/.test(char) || (keepSlash && char === "/")) return char;
      return `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
    })
    .join("");
}

export async function presignUrl(request: PresignRequest): Promise<string> {
  const timestamp = request.date.toISOString().replace(/[-:]|\.\d{3}/g, "");
  const day = timestamp.slice(0, 8);
  const scope = `${day}/${request.region}/${request.service}/aws4_request`;

  const headers = new Map<string, string>([["host", request.host]]);
  for (const [name, value] of Object.entries(request.signedHeaders ?? {})) {
    headers.set(name.toLowerCase(), value.trim());
  }
  const headerNames = [...headers.keys()].sort();
  const signedHeaders = headerNames.join(";");

  const query = new Map<string, string>([
    ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
    ["X-Amz-Credential", `${request.accessKeyId}/${scope}`],
    ["X-Amz-Date", timestamp],
    ["X-Amz-Expires", String(request.expiresSeconds)],
    ["X-Amz-SignedHeaders", signedHeaders],
  ]);
  const canonicalQuery = [...query.keys()]
    .sort()
    .map((key) => `${uriEncode(key)}=${uriEncode(query.get(key)!)}`)
    .join("&");
  const canonicalPath = uriEncode(request.path, true);

  const canonicalRequest = [
    request.method,
    canonicalPath,
    canonicalQuery,
    headerNames.map((name) => `${name}:${headers.get(name)}\n`).join(""),
    signedHeaders,
    "UNSIGNED-PAYLOAD",
  ].join("\n");
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    timestamp,
    scope,
    await sha256Hex(canonicalRequest),
  ].join("\n");

  let key: ArrayBuffer = await hmac(encoder.encode(`AWS4${request.secretAccessKey}`), day);
  for (const part of [request.region, request.service, "aws4_request"]) {
    key = await hmac(key, part);
  }
  const signature = hex(await hmac(key, stringToSign));

  return `https://${request.host}${canonicalPath}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

// One object per blob, `<workspace>/<blob>.enc`, as on the local disk.
export function r2ObjectUrl(
  accountId: string,
  bucket: string,
  workspace: string,
  blob: string,
): { host: string; path: string } {
  return {
    host: `${accountId}.r2.cloudflarestorage.com`,
    path: `/${bucket}/${workspace}/${blob}.enc`,
  };
}
