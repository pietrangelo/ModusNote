import assert from "node:assert/strict";
import test, { describe } from "node:test";

import { makeHandler, type HandlerConfig } from "./handler.ts";

const workspace = "00112233445566778899aabbccddeeff";
const origin = "https://modus.serv.run";
const secretAccessKey = "r2-secret-access-key-never-leaves";

type Call = { token: string; workspace: string };

function setup(authorize?: HandlerConfig["authorize"]) {
  const calls: Call[] = [];
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
  });
  return { handler, calls };
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

describe("adversary", () => {
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
