import {
  csvRecords,
  decimal,
  isoDate,
  normalizeRows,
  parseStatement,
  validateZip,
} from "../statements.ts";
import ExcelJS from "exceljs";
const assert = (ok: unknown, message = "Assertion failed") => {
  if (!ok) throw new Error(message);
};
function rejects(fn: () => unknown) {
  let failed = false;
  try {
    fn();
  } catch {
    failed = true;
  }
  assert(failed);
}

Deno.test("Brazilian decimal is exact and excludes zero/nonfinite/excess precision", () => {
  assert(decimal("R$ 1.234,56").amount === "1234.56");
  assert(decimal("(50,10)").negative);
  assert(decimal("0.01").amount === "0.01");
  for (
    const value of ["0", "NaN", "Infinity", "1.234", "100000000", "-", {}, null]
  ) rejects(() => decimal(value));
});
Deno.test("calendar validation rejects impossible dates without timezone shifts", () => {
  assert(isoDate("1/11/2026") === "2026-11-01");
  assert(isoDate("29/02/2024") === "2024-02-29");
  for (const value of ["31/02/2026", "2026-13-01", "2026-02-29", "invalid"]) {
    rejects(() => isoDate(value));
  }
});
Deno.test("CSV handles quotes, multiline descriptions and identical legitimate rows", () => {
  const rows = csvRecords(
    'Data;Descrição;Valor\r\n01/11/2026;"Serviço; com ""aspas""\nsegunda linha";1.000,00\r\n02/11/2026;Mesmo;100,00\r\n02/11/2026;Mesmo;100,00',
  );
  const parsed = normalizeRows(rows);
  assert(parsed.rows.length === 3 && parsed.rejected.length === 0);
  assert(
    parsed.rows[0].description.includes('"aspas"') &&
      parsed.rows[0].amount === "1000.00",
  );
});
Deno.test("invalid rows are visible and debit direction is explicit", () => {
  const parsed = normalizeRows([
    ["Data", "Descrição", "Crédito", "Débito"],
    ["2026-11-01", "fee", "", "50,00"],
    ["2026-02-31", "invalid", "100,00", ""],
    ["2026-11-01", "ambiguous", "10", "5"],
  ]);
  assert(parsed.rows.length === 1 && parsed.rows[0].direction === "debit");
  assert(parsed.rejected.length === 2);
});
Deno.test("XLSX parses native dates and rejects formula cells", async () => {
  const book = new ExcelJS.Workbook();
  const sheet = book.addWorksheet("statement");
  sheet.addRow(["Data", "Descrição", "Valor", "ID"]);
  sheet.addRow([
    new Date("2026-11-01T00:00:00Z"),
    "Synthetic",
    1234.56,
    "0001",
  ]);
  sheet.addRow([
    new Date("2026-11-01T00:00:00Z"),
    { formula: 'HYPERLINK("https://invalid.invalid")', result: "not executed" },
    1,
    "0002",
  ]);
  const bytes = new Uint8Array(await book.xlsx.writeBuffer());
  const parsed = await parseStatement(bytes, "synthetic.xlsx");
  assert(
    parsed.rows.length === 1 && parsed.rows[0].date === "2026-11-01" &&
      parsed.rows[0].amount === "1234.56" &&
      parsed.rows[0].external_id === "0001",
  );
  assert(
    parsed.rejected.length === 1 &&
      parsed.rejected[0].code === "UNSUPPORTED_CELL_FORMULA",
  );
});
Deno.test("unrecognized formats and oversized inputs do not enter workbook parser", async () => {
  rejects(() => validateZip(new Uint8Array(10)));
  let failed = false;
  try {
    await parseStatement(new Uint8Array(), "statement.xlsm");
  } catch {
    failed = true;
  }
  assert(failed);
  failed = false;
  try {
    await parseStatement(new Uint8Array(10 * 1024 * 1024 + 1), "statement.csv");
  } catch {
    failed = true;
  }
  assert(failed);
});
Deno.test("ZIP rejects forged zero counts, mismatched sizes and multiple disks", async () => {
  const book = new ExcelJS.Workbook();
  book.addWorksheet("bank").addRows([["Data", "Valor"], ["2026-11-01", 1]]);
  const original = new Uint8Array(await book.xlsx.writeBuffer());
  validateZip(original);
  let eocd = original.length - 22;
  while (new DataView(original.buffer).getUint32(eocd, true) !== 0x06054b50) {
    eocd--;
  }
  for (const offset of [4, 8, 10, 12]) {
    const bytes = original.slice();
    const view = new DataView(bytes.buffer);
    if (offset === 4) view.setUint16(eocd + offset, 1, true);
    else view.setUint16(eocd + offset, 0, true);
    rejects(() => validateZip(bytes));
  }
});
Deno.test("source row survives invalid and empty CSV/XLSX records", async () => {
  const parsed = normalizeRows(
    csvRecords("Data;Valor\n31/02/2026;1\n;\n2026-11-01;2"),
  );
  assert(
    parsed.rejected[0].source_row === 2 && parsed.rows[0].source_row === 4,
  );
  const book = new ExcelJS.Workbook();
  const sheet = book.addWorksheet("bank");
  sheet.addRow(["Data", "Valor"]);
  sheet.getRow(4).values = ["2026-11-01", 2];
  const result = await parseStatement(
    new Uint8Array(await book.xlsx.writeBuffer()),
    "fixture.xlsx",
  );
  assert(result.rows[0].source_row === 4);
});
