import assert from "node:assert/strict";
import test, { describe } from "node:test";

import { makeHandler, type HandlerConfig } from "./handler.ts";

const workspace = "00112233445566778899aabbccddeeff";
const origin = "https://modus.serv.run";
const secretAccessKey = "r2-secret-access-key-never-leaves";

type Call = { token: string; workspace: string };
type R2Call = { method: string; url: URL; headers: Record<string, string> };

function setup(
  authorize?: HandlerConfig["authorize"],
  r2Answer: (call: R2Call) => Response | Promise<Response> = () => new Response(null, { status: 204 }),
) {
  const calls: Call[] = [];
  const r2Calls: R2Call[] = [];
  const handler = makeHandler({
    allowedOrigin: origin,
    r2: {
      accountId: "acct",
      bucket: "modus-blobs",
      accessKeyId: "r2-access-key-id",
      secretAccessKey,
    },
    expiresSeconds: 300,
    now: () => new Date("2026-10-11T12:00:00Z"),
    authorize:
      authorize ??
      (async (token, workspace) => {
        calls.push({ token, workspace });
        return token === "member-token";
      }),
    r2Fetch: async (url, init) => {
      const call = { method: init.method, url: new URL(url), headers: init.headers };
      r2Calls.push(call);
      return r2Answer(call);
    },
  });
  return { handler, calls, r2Calls };
}

function listing(keys: { key: string; modified?: string; size?: number }[], next?: string) {
  const contents = keys
    .map(
      ({ key, modified = "2026-10-01T08:00:00.000Z", size = 4136 }) =>
        `<Contents><Key>${key}</Key><LastModified>${modified}</LastModified>` +
        `<ETag>"e"</ETag><Size>${size}</Size><StorageClass>STANDARD</StorageClass></Contents>`,
    )
    .join("");
  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` +
      `<Name>modus-blobs</Name>${contents}<IsTruncated>${next ? "true" : "false"}</IsTruncated>` +
      (next ? `<NextContinuationToken>${next}</NextContinuationToken>` : "") +
      `</ListBucketResult>`,
    { status: 200, headers: { "Content-Type": "application/xml" } },
  );
}

function request(
  body: unknown,
  { token = "member-token", method = "POST" }: { token?: string | null; method?: string } = {},
) {
  const headers: Record<string, string> = { Origin: origin };
  if (token !== null) headers.Authorization = `Bearer ${token}`;
  return new Request("https://project.supabase.co/functions/v1/blob-url", {
    method,
    headers,
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
}

test("a member gets a short-lived GET URL for the blob's object", async () => {
  const { handler, calls } = setup();

  const response = await handler(
    request({ workspace_id: workspace, blob_id: "voice-memo", method: "GET" }),
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), origin);
  const json = await response.json();
  const url = new URL(json.url);
  assert.equal(url.host, "acct.r2.cloudflarestorage.com");
  assert.equal(url.pathname, `/modus-blobs/${workspace}/voice-memo.enc`);
  assert.equal(url.searchParams.get("X-Amz-Expires"), "300");
  assert.equal(json.method, "GET");
  assert.deepEqual(json.headers, {});
  assert.equal(json.expires_in, 300);
  assert.deepEqual(calls, [{ token: "member-token", workspace }]);
});

test("a PUT URL only creates: it is signed with If-None-Match: *", async () => {
  const { handler } = setup();

  const response = await handler(
    request({ workspace_id: workspace, blob_id: "voice-memo", method: "PUT" }),
  );

  const json = await response.json();
  assert.equal(json.method, "PUT");
  assert.deepEqual(json.headers, { "If-None-Match": "*" });
  assert.equal(
    new URL(json.url).searchParams.get("X-Amz-SignedHeaders"),
    "host;if-none-match",
  );
});

test("the browser preflight is answered only for the app's origin", async () => {
  const { handler } = setup();
  const preflight = (from: string) =>
    handler(
      new Request("https://project.supabase.co/functions/v1/blob-url", {
        method: "OPTIONS",
        headers: { Origin: from },
      }),
    );

  const allowed = await preflight(origin);
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("Access-Control-Allow-Origin"), origin);
  assert.match(allowed.headers.get("Access-Control-Allow-Headers") ?? "", /authorization/i);

  const other = await preflight("https://evil.example");
  assert.equal(other.headers.get("Access-Control-Allow-Origin"), null);
});

describe("deleting", () => {
  test("the function deletes each blob of the workspace on R2 itself", async () => {
    const { handler, calls, r2Calls } = setup();

    const response = await handler(
      request({ workspace_id: workspace, method: "DELETE", blob_ids: ["take-1", "photo_2", "take-1"] }),
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { deleted: 2 });
    assert.deepEqual(calls, [{ token: "member-token", workspace }]);
    assert.deepEqual(
      r2Calls.map(({ method, url }) => [method, url.host, url.pathname]),
      [
        ["DELETE", "acct.r2.cloudflarestorage.com", `/modus-blobs/${workspace}/take-1.enc`],
        ["DELETE", "acct.r2.cloudflarestorage.com", `/modus-blobs/${workspace}/photo_2.enc`],
      ],
    );
    assert.match(
      r2Calls[0].headers.Authorization,
      /^AWS4-HMAC-SHA256 Credential=r2-access-key-id\/20261011\/auto\/s3\/aws4_request,/,
    );
    assert.equal(r2Calls[0].url.search, "", "nothing signed into the URL");
  });

  test("a blob R2 no longer has counts as deleted", async () => {
    const { handler } = setup(undefined, () => new Response("<Error/>", { status: 404 }));

    const response = await handler(
      request({ workspace_id: workspace, method: "DELETE", blob_ids: ["gone"] }),
    );

    assert.equal(response.status, 200);
  });

  test("R2 failing or unreachable is reported as unavailable, so the client retries", async () => {
    for (const answer of [
      () => new Response("<Error>InternalError secret detail</Error>", { status: 500 }),
      () => new Response("", { status: 403 }),
      () => {
        throw new TypeError("network down");
      },
    ]) {
      const { handler } = setup(undefined, answer);

      const response = await handler(
        request({ workspace_id: workspace, method: "DELETE", blob_ids: ["a", "b"] }),
      );

      assert.equal(response.status, 503);
      const text = await response.text();
      assert.equal(text.includes("secret detail") || text.includes("network down"), false);
    }
  });
});

describe("listing", () => {
  test("a member gets the ids, sizes and upload times of the workspace's blobs", async () => {
    const { handler, r2Calls } = setup(undefined, () =>
      listing([
        { key: `${workspace}/take-1.enc`, modified: "2026-10-01T08:00:00.000Z", size: 4136 },
        { key: `${workspace}/photo_2.enc`, modified: "2026-10-02T09:30:00.000Z", size: 99 },
      ]),
    );

    const response = await handler(request({ workspace_id: workspace, method: "LIST" }));

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      blobs: [
        { id: "take-1", size: 4136, stored_at: "2026-10-01T08:00:00.000Z" },
        { id: "photo_2", size: 99, stored_at: "2026-10-02T09:30:00.000Z" },
      ],
      cursor: null,
    });
    assert.equal(r2Calls.length, 1);
    const { method, url } = r2Calls[0];
    assert.equal(method, "GET");
    assert.equal(url.pathname, "/modus-blobs");
    assert.equal(url.searchParams.get("list-type"), "2");
    assert.equal(url.searchParams.get("prefix"), `${workspace}/`);
    assert.equal(url.searchParams.get("continuation-token"), null);
  });

  test("a long listing comes in pages joined by an opaque cursor", async () => {
    const { handler, r2Calls } = setup(undefined, ({ url }) =>
      url.searchParams.get("continuation-token") === "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM="
        ? listing([{ key: `${workspace}/last.enc` }])
        : listing([{ key: `${workspace}/first.enc` }], "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM="),
    );

    const first = await (await handler(request({ workspace_id: workspace, method: "LIST" }))).json();
    assert.equal(first.cursor, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=");
    const second = await (
      await handler(request({ workspace_id: workspace, method: "LIST", cursor: first.cursor }))
    ).json();

    assert.deepEqual(second.blobs.map((blob: { id: string }) => blob.id), ["last"]);
    assert.equal(second.cursor, null);
    assert.equal(r2Calls.length, 2);
  });

  test("R2 failing is reported as unavailable", async () => {
    const { handler } = setup(undefined, () => new Response("<Error/>", { status: 500 }));

    const response = await handler(request({ workspace_id: workspace, method: "LIST" }));

    assert.equal(response.status, 503);
  });
});

describe("adversary", () => {
  test("an account outside the workspace can neither delete nor list", async () => {
    const { handler, r2Calls } = setup();

    for (const body of [
      { workspace_id: workspace, method: "DELETE", blob_ids: ["take-1"] },
      { workspace_id: workspace, method: "LIST" },
    ]) {
      const response = await handler(request(body, { token: "outsider-token" }));
      assert.equal(response.status, 403);
    }
    assert.deepEqual(r2Calls, []);
  });

  test("a listing shows only the caller's workspace, whatever R2 answers", async () => {
    const other = "ffeeddccbbaa99887766554433221100";
    const { handler } = setup(undefined, () =>
      listing([
        { key: `${other}/someone-else.enc` },
        { key: `${workspace}/../${other}/x.enc` },
        { key: `${workspace}/nested/deeper.enc` },
        { key: `${workspace}/take-1.enc.part` },
        { key: `${workspace}/fine.enc`, size: -1 },
        { key: `${workspace}/fine.enc`, modified: "yesterday" },
        { key: `${workspace}/&lt;b&gt;.enc` },
        { key: `${workspace}/kept.enc` },
      ]),
    );

    const json = await (await handler(request({ workspace_id: workspace, method: "LIST" }))).json();

    assert.deepEqual(json.blobs.map((blob: { id: string }) => blob.id), ["kept"]);
  });

  test("malformed deletions and cursors are refused before authorizing", async () => {
    const { handler, calls, r2Calls } = setup();
    const malformed: unknown[] = [
      { workspace_id: workspace, method: "DELETE" },
      { workspace_id: workspace, method: "DELETE", blob_ids: [] },
      { workspace_id: workspace, method: "DELETE", blob_ids: "take-1" },
      { workspace_id: workspace, method: "DELETE", blob_ids: ["../other/blob"] },
      { workspace_id: workspace, method: "DELETE", blob_ids: ["ok", 7] },
      { workspace_id: workspace, method: "DELETE", blob_ids: Array.from({ length: 51 }, (_, i) => `b${i}`) },
      { workspace_id: workspace, method: "DELETE", blob_id: "take-1" },
      { workspace_id: workspace.toUpperCase(), method: "DELETE", blob_ids: ["take-1"] },
      { workspace_id: workspace, method: "LIST", cursor: "" },
      { workspace_id: workspace, method: "LIST", cursor: "has space" },
      { workspace_id: workspace, method: "LIST", cursor: "x".repeat(1025) },
      { workspace_id: workspace, method: "LIST", cursor: 7 },
      { method: "LIST" },
    ];

    for (const body of malformed) {
      const response = await handler(request(body));
      assert.equal(response.status, 400, JSON.stringify(body).slice(0, 120));
    }
    assert.deepEqual(calls, []);
    assert.deepEqual(r2Calls, []);
  });

  test("a full batch of the longest ids fits in one request", async () => {
    const { handler } = setup();
    const ids = Array.from({ length: 50 }, (_, i) => `${i}`.padStart(128, "x"));

    const response = await handler(request({ workspace_id: workspace, method: "DELETE", blob_ids: ids }));

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { deleted: 50 });
  });

  test("an account outside the workspace gets no URL", async () => {
    const { handler } = setup();

    const response = await handler(
      request(
        { workspace_id: workspace, blob_id: "voice-memo", method: "GET" },
        { token: "outsider-token" },
      ),
    );

    assert.equal(response.status, 403);
    assert.equal((await response.text()).includes("r2.cloudflarestorage"), false);
  });

  test("a request without a session token is refused before authorizing", async () => {
    const { handler, calls } = setup();

    for (const token of [null, ""]) {
      const response = await handler(
        request({ workspace_id: workspace, blob_id: "b", method: "GET" }, { token }),
      );
      assert.equal(response.status, 401);
    }
    assert.deepEqual(calls, []);
  });

  test("malformed ids, methods and bodies are refused before authorizing", async () => {
    const { handler, calls } = setup();
    const malformed: unknown[] = [
      "not json",
      "null",
      "[]",
      { workspace_id: workspace, blob_id: "../other/blob", method: "GET" },
      { workspace_id: workspace, blob_id: "a/b", method: "GET" },
      { workspace_id: workspace, blob_id: "", method: "GET" },
      { workspace_id: workspace, blob_id: "x".repeat(129), method: "GET" },
      { workspace_id: workspace.toUpperCase(), blob_id: "b", method: "GET" },
      { workspace_id: `${workspace}00`, blob_id: "b", method: "GET" },
      { workspace_id: workspace, blob_id: "b", method: "DELETE" },
      { workspace_id: workspace, blob_id: 7, method: "GET" },
      { workspace_id: workspace, method: "GET" },
    ];

    for (const body of malformed) {
      const response = await handler(request(body));
      assert.equal(response.status, 400, JSON.stringify(body));
    }
    assert.deepEqual(calls, []);
  });

  test("only POST is served", async () => {
    const { handler } = setup();

    const response = await handler(request(null, { method: "GET" }));

    assert.equal(response.status, 405);
  });

  test("an unreachable database is reported as unavailable, not as a refusal", async () => {
    const { handler } = setup(async () => {
      throw new Error("connection refused");
    });

    const response = await handler(
      request({ workspace_id: workspace, blob_id: "b", method: "GET" }),
    );

    assert.equal(response.status, 503);
    assert.equal((await response.text()).includes("connection refused"), false);
  });

  test("the R2 secret never appears in any response", async () => {
    const { handler } = setup();
    const bodies = [
      { workspace_id: workspace, blob_id: "b", method: "GET" },
      { workspace_id: workspace, blob_id: "b", method: "PUT" },
      { workspace_id: workspace, blob_id: "../b", method: "PUT" },
      { workspace_id: workspace, method: "DELETE", blob_ids: ["b"] },
      { workspace_id: workspace, method: "LIST" },
    ];

    for (const body of bodies) {
      for (const token of ["member-token", "outsider-token"]) {
        const response = await handler(request(body, { token }));
        const everything = [...response.headers].flat().join("\n") + (await response.text());
        assert.equal(everything.includes(secretAccessKey), false);
      }
    }
  });
});
