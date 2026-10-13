// deno-lint-ignore-file require-await -- Async dependency doubles intentionally return settled promises.
import { csvCell, downloadStream } from "../exports.ts";
const assert = (condition: unknown) => {
  if (!condition) throw new Error("Assertion failed");
};
Deno.test("CSV neutralizes formulas, quotes and keeps documents as text", () => {
  assert(csvCell("=1+1") === '"\'=1+1"');
  assert(csvCell('a,"b"') === '"a,""b"""');
  assert(csvCell("000123") === '"000123"');
});
Deno.test("export streams coherent JSON chunks and bounded CSV pages", async () => {
  const job = {
    id: "fixture",
    format: "json",
    part_count: 2,
    filters: { basis: "cash", from: "2026-11-01", to: "2026-11-30" },
    snapshot_at: "fixture",
    export_version: "finance-v1",
  };
  const get = async (
    i: number,
  ) => [{
    movement_id: String(i),
    amount: i ? "-1.00" : "2.00",
    invoice_number: "000123",
    description: "=bad",
  }];
  const result = await new Response(downloadStream(job, get)).json();
  assert(
    result.rows.length === 2 && result.rows[0].invoice_number === "000123",
  );
  const csv = await new Response(downloadStream({ ...job, format: "csv" }, get))
    .text();
  assert(
    csv.includes("' =bad") === false && csv.includes("'=bad") &&
      csv.includes('"-1.00"') && csv.includes("000123"),
  );
});
