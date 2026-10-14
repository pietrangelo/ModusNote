import assert from "node:assert/strict";
import test from "node:test";

import { makeHandler, type Database } from "./handler.ts";

const origin = "https://modus.serv.run";
const solo = "0123456789abcdef0123456789abcdef";
const other = "fedcba9876543210fedcba9876543210";

type R2Call = { method: string; url: URL };

function listing(keys: string[], next?: string) {
  const contents = keys
    .map(
      (key) =>
        `<Contents><Key>${key}</Key><LastModified>2026-10-01T08:00:00.000Z</LastModified>` +
        `<Size>4136</Size></Contents>`,
    )
    .join("");
  return new Response(
    `<ListBucketResult>${contents}<IsTruncated>${next ? "true" : "false"}</IsTruncated>` +
      (next ? `<NextContinuationToken>${next}</NextContinuationToken>` : "") +
      `</ListBucketResult>`,
    { status: 200 },
  );
}

function setup({
  database = {},
  r2 = (call: R2Call) =>
    call.method === "GET" ? listing([`${solo}/a.enc`, `${solo}/b.enc`]) : new Response(null, { status: 204 }),
}: {
  database?: Partial<Database>;
  r2?: (call: R2Call) => Response | Promise<Response>;
} = {}) {
  const log: string[] = [];
  const r2Calls: R2Call[] = [];
  const handler = makeHandler({
    allowedOrigin: origin,
    r2: { accountId: "acct", bucket: "modus-blobs", accessKeyId: "id", secretAccessKey: "key" },
    now: () => new Date("2026-10-14T12:00:00Z"),
    database: {
      soleWorkspaces:
        database.soleWorkspaces ??
        (async (token) => {
          log.push(`sole ${token}`);
          return token === "good" ? [solo] : null;
        }),
      deleteAccount:
        database.deleteAccount ??
        (async (token) => {
          log.push(`delete ${token}`);
          return token === "good" ? [solo] : null;
        }),
    },
    r2Fetch: async (url, init) => {
      const call = { method: init.method, url: new URL(url) };
      r2Calls.push(call);
      log.push(`r2 ${init.method}`);
      return r2(call);
    },
  });
  return { handler, log, r2Calls };
}

function request({
  token = "good",
  body = { confirm: "delete-account" } as unknown,
  method = "POST",
}: { token?: string | null; body?: unknown; method?: string } = {}) {
  const headers: Record<string, string> = { Origin: origin };
  if (token !== null) headers.Authorization = `Bearer ${token}`;
  return new Request("https://project.supabase.co/functions/v1/delete-account", {
    method,
    headers,
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
}

test("blobs go first, then the account, then any blob left behind", async () => {
  const { handler, log, r2Calls } = setup();

  const response = await handler(request());

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { deleted: true });
  assert.deepEqual(log, [
    "sole good",
    "r2 GET", "r2 DELETE", "r2 DELETE",
    "delete good",
    "r2 GET", "r2 DELETE", "r2 DELETE",
  ]);
  const deleted = r2Calls.filter((call) => call.method === "DELETE").map((call) => call.url.pathname);
  assert.deepEqual(deleted.slice(0, 2), [`/modus-blobs/${solo}/a.enc`, `/modus-blobs/${solo}/b.enc`]);
  const list = r2Calls[0].url;
  assert.equal(list.pathname, "/modus-blobs");
  assert.equal(list.searchParams.get("prefix"), `${solo}/`);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), origin);
});

test("every page of the listing is deleted", async () => {
  const { handler, r2Calls } = setup({
    database: { deleteAccount: async () => [] },
    r2: (call) => {
      if (call.method !== "GET") return new Response(null, { status: 204 });
      return call.url.searchParams.get("continuation-token") === "page-2"
        ? listing([`${solo}/c.enc`])
        : listing([`${solo}/a.enc`], "page-2");
    },
  });

  assert.equal((await handler(request())).status, 200);
  assert.deepEqual(
    r2Calls.filter((call) => call.method === "DELETE").map((call) => call.url.pathname),
    [`/modus-blobs/${solo}/a.enc`, `/modus-blobs/${solo}/c.enc`],
  );
});

test("a refused session deletes nothing", async () => {
  const { handler, log } = setup();

  const response = await handler(request({ token: "stolen" }));

  assert.equal(response.status, 401);
  assert.deepEqual(log, ["sole stolen"]);
});

test("adversary: no session, wrong body or wrong method is refused before anything", async () => {
  for (const [req, status] of [
    [request({ token: null }), 401],
    [request({ body: {} }), 400],
    [request({ body: { confirm: "delete-account", extra: 1 } }), 400],
    [request({ body: "not json" }), 400],
    [request({ method: "GET" }), 405],
  ] as const) {
    const { handler, log } = setup();
    assert.equal((await handler(req)).status, status);
    assert.deepEqual(log, []);
  }
});

test("when R2 fails the account stays, so the request can be repeated", async () => {
  for (const r2 of [
    () => new Response("no", { status: 500 }),
    (call: R2Call) => (call.method === "GET" ? listing([`${solo}/a.enc`]) : new Response(null, { status: 403 })),
    (call: R2Call) => (call.method === "GET" ? listing([`${solo}/a.enc`], "loop") : new Response(null, { status: 204 })),
    () => Promise.reject(new Error("network")),
  ]) {
    const { handler, log } = setup({ r2 });
    const response = await handler(request());
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: "storage unavailable" });
    assert.ok(!log.includes("delete good"));
  }
});

test("an object already gone counts as deleted", async () => {
  const { handler } = setup({
    r2: (call) => (call.method === "GET" ? listing([`${solo}/a.enc`]) : new Response(null, { status: 404 })),
  });

  assert.equal((await handler(request())).status, 200);
});

test("adversary: only objects of the sole workspaces are touched", async () => {
  const { handler, r2Calls } = setup({
    r2: (call) =>
      call.method === "GET"
        ? listing([`${solo}/a.enc`, `${other}/x.enc`, `${solo}/../x.enc`, `${solo}/a.txt`])
        : new Response(null, { status: 204 }),
  });

  assert.equal((await handler(request())).status, 200);
  const deleted = new Set(
    r2Calls.filter((call) => call.method === "DELETE").map((call) => call.url.pathname),
  );
  assert.deepEqual([...deleted], [`/modus-blobs/${solo}/a.enc`]);
});

test("adversary: a workspace id the database should never return is refused", async () => {
  const { handler, log } = setup({ database: { soleWorkspaces: async () => ["../../etc"] } });

  assert.equal((await handler(request())).status, 503);
  assert.ok(!log.some((line) => line.startsWith("r2") || line.startsWith("delete")));
});

test("a database failure is a 503 and deletes nothing more", async () => {
  const unavailable = async (): Promise<string[]> => {
    throw new Error("down");
  };
  const first = setup({ database: { soleWorkspaces: unavailable } });
  assert.equal((await first.handler(request())).status, 503);
  assert.deepEqual(first.log, []);

  const second = setup({ database: { deleteAccount: unavailable } });
  const response = await second.handler(request());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "database unavailable" });
});

test("R2 failing after the account is gone still reports it deleted", async () => {
  let lists = 0;
  const { handler } = setup({
    r2: (call) => {
      if (call.method !== "GET") return new Response(null, { status: 204 });
      return ++lists === 1 ? listing([]) : new Response(null, { status: 500 });
    },
  });

  assert.equal((await handler(request())).status, 200);
});

test("an account alone in nothing still deletes itself", async () => {
  const { handler, log } = setup({
    database: { soleWorkspaces: async () => [], deleteAccount: async () => [] },
  });

  assert.equal((await handler(request())).status, 200);
  assert.deepEqual(log, []);
});

test("the preflight allows only the app's origin", async () => {
  const { handler } = setup();
  const allowed = await handler(request({ method: "OPTIONS" }));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("Access-Control-Allow-Origin"), origin);

  const elsewhere = await handler(
    new Request("https://project.supabase.co/functions/v1/delete-account", {
      method: "OPTIONS",
      headers: { Origin: "https://evil.example" },
    }),
  );
  assert.equal(elsewhere.headers.get("Access-Control-Allow-Origin"), null);
});
