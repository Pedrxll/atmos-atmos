import { inflateRawSync } from "node:zlib";

export type BankRow = {
  source_row: number;
  date: string;
  amount: string;
  direction: "credit" | "debit";
  description: string;
  external_id?: string;
};
export type ParsedStatement = {
  rows: BankRow[];
  rejected: { source_row: number; code: string }[];
};

const normalize = (s: string) =>
  s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(
    /[^a-z0-9]/g,
    "",
  );
const aliases = {
  date: ["data", "date", "datatransacao", "transactiondate", "dt"],
  amount: ["valor", "amount", "value", "quantia"],
  credit: ["credito", "credit", "entrada"],
  debit: ["debito", "debit", "saida"],
  description: ["descricao", "historico", "description", "memo"],
  external_id: ["id", "identificador", "documento", "transactionid", "fitid"],
};

export function decimal(input: unknown): { amount: string; negative: boolean } {
  if (input === null || input === undefined || typeof input === "object") {
    throw new Error("INVALID_BANK_AMOUNT");
  }
  let s = String(input).trim().replace(/R\$|BRL/gi, "").replace(/\s/g, "");
  const negative = s.startsWith("-") || /^\(.*\)$/.test(s);
  s = s.replace(/^\((.*)\)$/, "$1").replace(/^[+-]/, "");
  if (s.includes(",")) s = s.replace(/\./g, "").replace(",", ".");
  if (!/^\d{1,8}(\.\d{1,2})?$/.test(s)) throw new Error("INVALID_BANK_AMOUNT");
  const [whole, fraction = ""] = s.split(".");
  const cents = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
  if (cents <= 0n || cents >= 10000000000n) {
    throw new Error("INVALID_BANK_AMOUNT");
  }
  return {
    amount: `${cents / 100n}.${String(cents % 100n).padStart(2, "0")}`,
    negative,
  };
}

export function isoDate(value: unknown): string {
  let s: string;
  if (value instanceof Date && Number.isFinite(value.getTime())) {
    s = value.toISOString().slice(0, 10);
  } else {
    s = String(value ?? "").trim();
    const br = s.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
    if (br) s = `${br[3]}-${br[2].padStart(2, "0")}-${br[1].padStart(2, "0")}`;
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) throw new Error("INVALID_BANK_DATE");
  const d = new Date(`${s}T00:00:00Z`);
  if (!Number.isFinite(d.getTime()) || d.toISOString().slice(0, 10) !== s) {
    throw new Error("INVALID_BANK_DATE");
  }
  return s;
}

export function csvRecords(text: string): string[][] {
  text = text.replace(/^\uFEFF/, "");
  const first = text.split(/\r?\n/, 1)[0];
  const delimiter =
    (first.match(/;/g)?.length ?? 0) > (first.match(/,/g)?.length ?? 0)
      ? ";"
      : ",";
  const records: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') {
      if (quoted && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (quoted || field.length === 0) quoted = !quoted;
      else throw new Error("INVALID_CSV_QUOTE");
    } else if (!quoted && char === delimiter) {
      row.push(field);
      field = "";
    } else if (!quoted && (char === "\n" || char === "\r")) {
      if (char === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      records.push(row);
      row = [];
      field = "";
    } else field += char;
    if (field.length > 10000 || row.length > 100 || records.length > 20001) {
      throw new Error("STATEMENT_LIMIT_EXCEEDED");
    }
  }
  if (quoted) throw new Error("INVALID_CSV_QUOTE");
  row.push(field);
  if (row.some((v) => v.trim())) records.push(row);
  return records;
}

export function validateZip(bytes: Uint8Array): void {
  if (bytes.length > 10 * 1024 * 1024) throw new Error("PAYLOAD_TOO_LARGE");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("INVALID_XLSX_ZIP");
  if (
    eocd + 22 + view.getUint16(eocd + 20, true) !== bytes.length ||
    view.getUint16(eocd + 4, true) !== 0 ||
    view.getUint16(eocd + 6, true) !== 0 ||
    view.getUint16(eocd + 8, true) !== view.getUint16(eocd + 10, true)
  ) throw new Error("INVALID_XLSX_ZIP");
  const entries = view.getUint16(eocd + 10, true);
  const size = view.getUint32(eocd + 12, true);
  let pos = view.getUint32(eocd + 16, true);
  if (
    entries === 0 || entries > 1000 || pos + size !== eocd || size === 0 ||
    pos === 0xffffffff || size === 0xffffffff
  ) throw new Error("STATEMENT_LIMIT_EXCEEDED");
  let cells = 0;
  let strings = 0;
  let rows = 0;
  let expanded = 0;
  let count = 0;
  const names = new Set<string>();
  while (pos < eocd) {
    if (++count > 1000) throw new Error("STATEMENT_LIMIT_EXCEEDED");
    if (pos + 46 > eocd || view.getUint32(pos, true) !== 0x02014b50) {
      throw new Error("INVALID_XLSX_ZIP");
    }
    const flags = view.getUint16(pos + 8, true);
    const method = view.getUint16(pos + 10, true);
    const compressed = view.getUint32(pos + 20, true);
    const raw = view.getUint32(pos + 24, true);
    const nameLength = view.getUint16(pos + 28, true);
    const extraLength = view.getUint16(pos + 30, true);
    const commentLength = view.getUint16(pos + 32, true);
    if (
      compressed === 0xffffffff || raw === 0xffffffff ||
      view.getUint16(pos + 34, true) !== 0 ||
      pos + 46 + nameLength + extraLength + commentLength > eocd
    ) throw new Error("INVALID_XLSX_ZIP");
    expanded += raw;
    if (
      flags & 1 || raw > 20 * 1024 * 1024 || expanded > 50 * 1024 * 1024 ||
      (raw > 1024 * 1024 && raw > Math.max(1, compressed) * 100)
    ) throw new Error("STATEMENT_LIMIT_EXCEEDED");
    const name = new TextDecoder().decode(
      bytes.subarray(pos + 46, pos + 46 + nameLength),
    );
    if (
      !name || names.has(name) || name.startsWith("/") || name.includes("\\") ||
      name.split("/").includes("..") || /vbaProject|\.bin$/i.test(name)
    ) throw new Error("UNSUPPORTED_FILE");
    names.add(name);
    const local = view.getUint32(pos + 42, true);
    if (
      local + 30 > bytes.length || view.getUint32(local, true) !== 0x04034b50 ||
      ![0, 8].includes(method)
    ) throw new Error("INVALID_XLSX_ZIP");
    if (
      view.getUint16(local + 6, true) !== flags ||
      view.getUint16(local + 8, true) !== method ||
      new TextDecoder().decode(
          bytes.subarray(
            local + 30,
            local + 30 + view.getUint16(local + 26, true),
          ),
        ) !== name
    ) throw new Error("INVALID_XLSX_ZIP");
    const dataStart = local + 30 + view.getUint16(local + 26, true) +
      view.getUint16(local + 28, true);
    if (dataStart + compressed > view.getUint32(eocd + 16, true)) {
      throw new Error("INVALID_XLSX_ZIP");
    }
    // Verify actual expansion before handing the workbook to the XML parser;
    // central-directory size claims alone cannot prevent a deflate bomb.
    try {
      const contents = method === 0
        ? bytes.subarray(dataStart, dataStart + compressed)
        : inflateRawSync(bytes.subarray(dataStart, dataStart + compressed), {
          maxOutputLength: Math.min(20 * 1024 * 1024, raw + 1),
        });
      if (contents.length !== raw) throw new Error("INVALID_XLSX_ZIP");
      if (/\.xml$/i.test(name)) {
        const xml = new TextDecoder().decode(contents);
        if (/<!DOCTYPE|<!ENTITY/i.test(xml)) {
          throw new Error("UNSUPPORTED_FILE");
        }
        for (
          const tag of xml.matchAll(/<(?:[A-Za-z0-9_]+:)?(row|c|si)\b[^>]*>/g)
        ) {
          if (tag[1] === "c") cells++;
          else if (tag[1] === "si") strings++;
          else rows++;
          const position = tag[0].match(
            /\br\s*=\s*["']([A-Za-z]*)([0-9]+)["']/,
          );
          if (position) {
            let column = 0;
            for (const letter of position[1].toUpperCase()) {
              column = column * 26 + letter.charCodeAt(0) - 64;
            }
            if (column > 100 || Number(position[2]) > 20001) {
              throw new Error("STATEMENT_LIMIT_EXCEEDED");
            }
          }
          if (cells > 200000 || strings > 120000 || rows > 20001) {
            throw new Error("STATEMENT_LIMIT_EXCEEDED");
          }
        }
      }
    } catch {
      throw new Error("STATEMENT_LIMIT_EXCEEDED");
    }
    pos += 46 + nameLength + extraLength + commentLength;
    if (pos > eocd) throw new Error("INVALID_XLSX_ZIP");
  }
  if (count !== entries || pos !== eocd) throw new Error("INVALID_XLSX_ZIP");
}

export function normalizeRows(records: unknown[][]): ParsedStatement {
  if (!records.length || records.length > 20001) {
    throw new Error("STATEMENT_LIMIT_EXCEEDED");
  }
  const headers = records[0].map((v) => normalize(String(v ?? "")));
  const columns = Object.fromEntries(
    Object.entries(aliases).map((
      [name, names],
    ) => [name, headers.findIndex((v) => names.includes(v))]),
  ) as Record<keyof typeof aliases, number>;
  if (
    columns.date < 0 ||
    [columns.amount, columns.credit, columns.debit].every((v) => v < 0)
  ) throw new Error("INVALID_STATEMENT_HEADERS");
  const rows: BankRow[] = [];
  const rejected: ParsedStatement["rejected"] = [];
  for (let i = 1; i < records.length; i++) {
    const record = records[i];
    if (
      record.every((v) =>
        v === null || v === undefined || String(v).trim() === ""
      )
    ) continue;
    try {
      if (
        record.some((v) =>
          typeof v === "object" && v !== null && !(v instanceof Date)
        )
      ) throw new Error("UNSUPPORTED_CELL_FORMULA");
      const credit = record[columns.credit];
      const debit = record[columns.debit];
      const hasCredit = credit !== undefined && String(credit).trim() !== "" &&
        !/^0([.,]0+)?$/.test(String(credit));
      const hasDebit = debit !== undefined && String(debit).trim() !== "" &&
        !/^0([.,]0+)?$/.test(String(debit));
      if (hasCredit && hasDebit) throw new Error("AMBIGUOUS_BANK_DIRECTION");
      const amount = decimal(
        hasCredit ? credit : hasDebit ? debit : record[columns.amount],
      );
      if (hasCredit && amount.negative) {
        throw new Error("AMBIGUOUS_BANK_DIRECTION");
      }
      const description = String(record[columns.description] ?? "").trim();
      if (description.length > 2000) {
        throw new Error("STATEMENT_LIMIT_EXCEEDED");
      }
      rows.push({
        source_row: i + 1,
        date: isoDate(record[columns.date]),
        amount: amount.amount,
        direction: hasDebit || (!hasCredit && amount.negative)
          ? "debit"
          : "credit",
        description,
        external_id: String(record[columns.external_id] ?? "").trim() ||
          undefined,
      });
    } catch (e) {
      rejected.push({
        source_row: i + 1,
        code: e instanceof Error ? e.message : "INVALID_BANK_ROW",
      });
    }
  }
  return { rows, rejected };
}

export async function parseStatement(
  bytes: Uint8Array,
  filename: string,
): Promise<ParsedStatement> {
  if (bytes.length > 10 * 1024 * 1024) throw new Error("PAYLOAD_TOO_LARGE");
  if (/\.csv$/i.test(filename)) {
    return normalizeRows(
      csvRecords(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
    );
  }
  if (!/\.xlsx$/i.test(filename)) throw new Error("UNSUPPORTED_FILE");
  validateZip(bytes);
  const { default: ExcelJS } = await import("exceljs");
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(
    bytes as unknown as Parameters<typeof workbook.xlsx.load>[0],
  );
  if (workbook.worksheets.length !== 1) throw new Error("UNSUPPORTED_FILE");
  const sheet = workbook.worksheets[0];
  if (!sheet) throw new Error("INVALID_STATEMENT_HEADERS");
  if (sheet.rowCount > 20001 || sheet.columnCount > 100) {
    throw new Error("STATEMENT_LIMIT_EXCEEDED");
  }
  const records: unknown[][] = [];
  for (let rowNumber = 1; rowNumber <= sheet.rowCount; rowNumber++) {
    const row = sheet.getRow(rowNumber);
    records.push(
      Array.from(
        { length: sheet.columnCount },
        (_, i) => row.getCell(i + 1).value,
      ),
    );
  }
  return normalizeRows(records);
}
