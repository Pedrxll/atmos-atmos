type Json = Record<string, unknown>;
export const columns = [
  "job_id",
  "snapshot_at",
  "basis",
  "from",
  "to",
  "export_version",
  "movement_id",
  "transaction_id",
  "type",
  "description",
  "amount",
  "report_date",
  "proposal_id",
  "proposal_code",
  "proposal_title",
  "origin_type",
  "finance_scope",
  "branch_id",
  "account_id",
  "account_code",
  "account_name",
  "supplier_id",
  "supplier_name",
  "bank_account_id",
  "bank_name",
  "invoice_number",
  "finance_managed",
];
export function csvCell(value: unknown): string {
  let text = value === null || value === undefined ? "" : String(value);
  // Spreadsheet programs may interpret a quoted text cell as a formula.
  let first = 0;
  while (
    first < text.length &&
    (text.charCodeAt(first) <= 31 || /\s/u.test(text[first]))
  ) first++;
  if (first < text.length && "=+@-".includes(text[first])) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}
export function csvRows(rows: Json[], job: Json): string {
  const filters = job.filters as Json;
  return rows.map((row) => {
    const full = {
      job_id: job.id,
      snapshot_at: job.snapshot_at,
      ...filters,
      export_version: job.export_version,
      ...row,
    } as Json;
    return columns.map((key) =>
      key === "amount"
        ? csvCell(row.amount).replace(/^"'(-\d+(\.\d+)?)"$/, '"$1"')
        : csvCell(full[key])
    ).join(",");
  }).join("\r\n") + (rows.length ? "\r\n" : "");
}

export function downloadStream(
  job: Json,
  getPart: (part: number) => Promise<Json[]>,
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  let part = -1;
  let hasRows = false;
  return new ReadableStream({
    async pull(controller) {
      try {
        if (part < 0) {
          controller.enqueue(
            encoder.encode(
              job.format === "csv"
                ? `\uFEFF${columns.join(",")}\r\n`
                : `{"metadata":${JSON.stringify(job)},"rows":[`,
            ),
          );
          part = 0;
          return;
        }
        if (part >= Number(job.part_count)) {
          if (job.format === "json") controller.enqueue(encoder.encode("]}"));
          controller.close();
          return;
        }
        const rows = await getPart(part++);
        if (job.format === "csv") {
          controller.enqueue(encoder.encode(csvRows(rows, job)));
        } else if (rows.length) {
          controller.enqueue(
            encoder.encode(
              (hasRows ? "," : "") + JSON.stringify(rows).slice(1, -1),
            ),
          );
          hasRows = true;
        }
      } catch {
        controller.error(new Error("EXPORT_DOWNLOAD_INTERRUPTED"));
      }
    },
  });
}
