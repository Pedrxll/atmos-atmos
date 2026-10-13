// deno-lint-ignore-file require-await -- Async dependency doubles intentionally return settled promises.
import { createEnrichmentHandler } from "../../enrich-prospect/handler.ts";
const assert = (condition: unknown) => {
  if (!condition) throw new Error("Assertion failed");
};
const req = (body: unknown = { name: "Synthetic" }) =>
  new Request("https://fixture.invalid/enrich", {
    method: "POST",
    body: JSON.stringify(body),
  });
Deno.test("enrichment denies before integration and distinguishes missing configuration", async () => {
  let called = false;
  const fetcher: typeof fetch = async () => {
    called = true;
    throw new Error();
  };
  assert(
    (await createEnrichmentHandler({
      authorize: async () => new Response(null, { status: 403 }),
      apiKey: "synthetic",
      fetch: fetcher,
    })(req())).status === 403,
  );
  assert(
    (await createEnrichmentHandler({
      authorize: async () => null,
      fetch: fetcher,
    })(req())).status === 503,
  );
  assert(!called);
});
Deno.test("enrichment preserves actionable gateway and parsing failures", async () => {
  for (const status of [402, 429]) {
    assert(
      (await createEnrichmentHandler({
        authorize: async () => null,
        apiKey: "synthetic",
        fetch: async () => new Response(null, { status }),
      })(req())).status === status,
    );
  }
  for (const content of ["invalid", "{}", '{"website":"javascript:bad"}']) {
    const response = await createEnrichmentHandler({
      authorize: async () => null,
      apiKey: "synthetic",
      fetch: async () => Response.json({ choices: [{ message: { content } }] }),
    })(req());
    assert([422, 502].includes(response.status));
  }
});
Deno.test("enrichment returns timeout and reviewed data, never upstream key/error text", async () => {
  let response = await createEnrichmentHandler({
    authorize: async () => null,
    apiKey: "synthetic",
    fetch: async () => {
      throw new DOMException("private details", "TimeoutError");
    },
  })(req());
  assert(
    response.status === 504 &&
      !(await response.text()).includes("private details"),
  );
  response = await createEnrichmentHandler({
    authorize: async () => null,
    apiKey: "synthetic",
    fetch: async () =>
      Response.json({
        choices: [{ message: { content: '{"description":"Fixture"}' } }],
      }),
  })(req());
  const body = await response.json();
  assert(body.result.description === "Fixture" && body.requires_review);
});
