// deno-lint-ignore-file require-await -- Async dependency doubles intentionally return settled promises.
import { createHandler } from "../handler.ts";

const assert = (ok: unknown, message = "Assertion failed") => {
  if (!ok) throw new Error(message);
};
const options = {
  supabaseUrl: "https://fixture.supabase.co",
  anonKey: "test-public-key",
  allowedOrigins: ["https://admin.example.invalid"],
};
const request = (
  path: string,
  method = "GET",
  body?: unknown,
  headers: Record<string, string> = {},
) =>
  new Request(
    `https://fixture.supabase.co/functions/v1/finance-api/v1${path}`,
    {
      method,
      headers: {
        Authorization: "Bearer test-session",
        ...(body ? { "Content-Type": "application/json" } : {}),
        ...headers,
      },
      body: body ? JSON.stringify(body) : undefined,
    },
  );

Deno.test("finance handler denies missing session and disallowed origins without calling dependencies", async () => {
  let called = false;
  const handler = createHandler({
    ...options,
    fetch: (() => {
      called = true;
      throw new Error("must not call");
    }) as typeof fetch,
  });
  assert(
    (await handler(new Request("https://fixture.invalid/v1/transactions")))
      .status === 401,
  );
  assert(
    (await handler(
      request("/transactions", "GET", undefined, {
        origin: "https://other.example.invalid",
      }),
    )).status === 403,
  );
  assert(!called);
});

Deno.test("preflight has a restricted origin and no credentials", async () => {
  const handler = createHandler(options);
  const response = await handler(
    request("/transactions", "OPTIONS", undefined, {
      origin: options.allowedOrigins[0],
    }),
  );
  assert(response.status === 204);
  assert(
    response.headers.get("access-control-allow-origin") ===
      options.allowedOrigins[0],
  );
  assert(!response.headers.has("access-control-allow-credentials"));
});

Deno.test("command forwards the user JWT and idempotency key, never a service credential", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async (input, init) => {
    calls++;
    assert(
      (init?.headers as Record<string, string>).Authorization ===
        "Bearer test-session",
    );
    if (String(input).endsWith("/auth/v1/user")) {
      return Response.json({ id: "11111111-1111-4111-8111-111111111111" });
    }
    const body = JSON.parse(String(init?.body));
    assert(body.p_action === "settlement.create");
    assert(
      body.p_payload.transaction_id === "22222222-2222-4222-8222-222222222222",
    );
    assert(
      body.p_payload.amount === "1000.00" &&
        body.p_idempotency_key === "fixture-payment-01",
    );
    return Response.json({ data: { balance: "1500.00" }, replayed: false });
  };
  const response = await createHandler({ ...options, fetch: fetcher })(
    request(
      "/transactions/22222222-2222-4222-8222-222222222222/settlements",
      "POST",
      { amount: "1000.00", expected_version: 1 },
      { "idempotency-key": "fixture-payment-01" },
    ),
  );
  const body = await response.json();
  assert(response.status === 200 && body.data.balance === "1500.00");
  assert(calls === 2);
  assert(
    response.headers.get("cache-control") === "no-store" && body.request_id,
  );
});

Deno.test("invalid session cannot reach the RPC", async () => {
  let calls = 0;
  const handler = createHandler({
    ...options,
    fetch: async () => {
      calls++;
      return Response.json({ error: "invalid" }, { status: 401 });
    },
  });
  assert((await handler(request("/transactions"))).status === 401);
  assert(calls === 1);
});

Deno.test("conflicts preserve codes and redact database details", async () => {
  const handler = createHandler({
    ...options,
    fetch: async (input) =>
      String(input).endsWith("/user")
        ? Response.json({ id: "fixture-user" })
        : Response.json({
          error: {
            code: "VERSION_CONFLICT",
            sqlstate: "40001",
            detail: "private constraint and internal stack",
            retryable: false,
          },
        }),
  });
  const response = await handler(
    request("/transactions", "POST", { amount: "1.00" }, {
      "idempotency-key": "fixture-conflict-01",
    }),
  );
  const text = await response.text();
  assert(response.status === 409 && text.includes("VERSION_CONFLICT"));
  assert(!text.includes("constraint") && !text.includes("sqlstate"));
});

Deno.test("pagination and explicit report basis are forwarded as typed params", async () => {
  const handler = createHandler({
    ...options,
    fetch: async (input, init) => {
      if (String(input).endsWith("/user")) {
        return Response.json({ id: "fixture-user" });
      }
      const body = JSON.parse(String(init?.body));
      assert(body.p_action === "report.detail");
      assert(body.p_payload.basis === "cash");
      assert(body.p_payload.limit === 50);
      return Response.json({ data: {} });
    },
  });
  assert(
    (await handler(
      request(
        "/reports/detail?from=2026-11-01&to=2026-11-30&basis=cash&limit=50",
      ),
    )).status === 200,
  );
});

Deno.test("malformed body and missing idempotency key return 400", async () => {
  let rpc = false;
  const handler = createHandler({
    ...options,
    fetch: async (input) => {
      if (!String(input).endsWith("/user")) rpc = true;
      return Response.json({ id: "fixture-user" });
    },
  });
  const malformed = request("/transactions", "POST", { amount: 1 });
  assert((await handler(malformed)).status === 400);
  assert(!rpc);
  assert(
    (await handler(
      new Request(malformed.url, {
        method: "POST",
        headers: malformed.headers,
        body: "{",
      }),
    )).status === 400,
  );
});

Deno.test("database rate limit becomes 429 with Retry-After", async () => {
  const handler = createHandler({
    ...options,
    fetch: async (input) =>
      String(input).endsWith("/user")
        ? Response.json({ id: "fixture-user" })
        : Response.json({ code: "P0429", message: "private" }, { status: 400 }),
  });
  const response = await handler(request("/transactions"));
  assert(
    response.status === 429 && response.headers.get("retry-after") === "60",
  );
});

Deno.test("timeouts return retryable 504 with correlation and no input leak", async () => {
  const handler = createHandler({
    ...options,
    fetch: async () => {
      throw new DOMException("sensitive upstream payload", "TimeoutError");
    },
  });
  const response = await handler(request("/transactions"));
  const text = await response.text();
  assert(
    response.status === 504 && text.includes('"retryable":true') &&
      !text.includes("sensitive"),
  );
});
Deno.test("body deadline cancels an unfinished upload", async () => {
  let cancelled = false;
  const handler = createHandler({
    ...options,
    timeoutMs: 10,
    fetch: async () => Response.json({ id: "fixture-user" }),
  });
  const stream = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("{"));
    },
    cancel() {
      cancelled = true;
    },
  });
  const response = await handler(
    new Request("https://fixture.invalid/v1/transactions", {
      method: "POST",
      headers: {
        authorization: "Bearer fixture",
        "idempotency-key": "fixture-hanging-body",
      },
      body: stream,
    }),
  );
  assert(response.status === 504 && cancelled);
});
Deno.test("upload authorization and idempotency precede XLSX processing", async () => {
  let calls = 0;
  const handler = createHandler({
    ...options,
    fetch: async (input) => {
      calls++;
      return String(input).endsWith("/user")
        ? Response.json({ id: "fixture-user" })
        : Response.json({ code: "42501" }, { status: 403 });
    },
  });
  const response = await handler(
    new Request(
      "https://fixture.invalid/v1/bank-imports/file-preview?filename=fixture.xlsx&bank_account_id=fixture",
      {
        method: "POST",
        headers: {
          authorization: "Bearer fixture",
          "idempotency-key": "fixture-upload-01",
        },
        body: new Uint8Array([1, 2, 3]),
      },
    ),
  );
  assert(response.status === 403 && calls === 2);
});
