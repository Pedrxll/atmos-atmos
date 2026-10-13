import { downloadStream } from "./exports.ts";
import { parseStatement } from "./statements.ts";

type Json = Record<string, unknown>;
export type Config = {
  supabaseUrl: string;
  anonKey: string;
  allowedOrigins: string[];
  fetch?: typeof fetch;
  timeoutMs?: number;
  background?: (task: Promise<unknown>) => void;
};
const errorStatuses: Record<string, number> = {
  INVALID_REQUEST: 400,
  NOT_FOUND: 404,
  MODULE_FORBIDDEN: 403,
  RECORD_FORBIDDEN: 403,
  AUTH_REQUIRED: 401,
  VERSION_CONFLICT: 409,
  IDEMPOTENCY_CONFLICT: 409,
  LEGACY_REVIEW_REQUIRED: 409,
  ADJUSTMENT_REQUIRED: 409,
  SUPPLIER_REVIEW_REQUIRED: 409,
  PIPELINE_STAGE_REQUIRED: 422,
  OVERLAP_REVIEW_REQUIRED: 409,
  UNSUPPORTED_MATCH_MODE: 422,
  EXPORT_EXPIRED: 410,
  EXPORT_NOT_READY: 409,
  DECISION_REQUIRED: 422,
  INVALID_TRANSITION: 422,
  FINANCIAL_DATA_REQUIRED: 422,
  RATE_LIMITED: 429,
  PAYLOAD_TOO_LARGE: 413,
  UNSUPPORTED_FILE: 415,
  DEPENDENCY_UNAVAILABLE: 503,
  TIMEOUT: 504,
};

async function limitedBody(
  request: Request,
  maximum: number,
  signal: AbortSignal,
): Promise<Uint8Array> {
  const length = Number(request.headers.get("content-length") || 0);
  if (length > maximum) throw new Error("PAYLOAD_TOO_LARGE");
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  let abort: () => void = () => {};
  const aborted = new Promise<never>((_, reject) => {
    abort = () => {
      void reader.cancel().catch(() => {});
      reject(signal.reason ?? new DOMException("Aborted", "AbortError"));
    };
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
  try {
    while (true) {
      const { done, value } = await Promise.race([reader.read(), aborted]);
      if (signal.aborted) throw signal.reason;
      if (done) break;
      size += value.length;
      if (size > maximum) {
        await reader.cancel();
        throw new Error("PAYLOAD_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    signal.removeEventListener("abort", abort);
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

function route(
  method: string,
  path: string,
  body: Json,
  search: URLSearchParams,
): { query: boolean; action: string; payload: Json } {
  const params = Object.fromEntries(search.entries()) as Json;
  if (typeof params.limit === "string") params.limit = Number(params.limit);
  if (typeof params.part_number === "string") {
    params.part_number = Number(params.part_number);
  }
  if (params.overdue === "true" || params.overdue === "false") {
    params.overdue = params.overdue === "true";
  }
  let match: RegExpMatchArray | null;
  if (method === "POST" && (match = path.match(/^\/commands\/([a-z.]+)$/))) {
    return { query: false, action: match[1], payload: body };
  }
  if (method === "GET" && (match = path.match(/^\/queries\/([a-z.]+)$/))) {
    return { query: true, action: match[1], payload: params };
  }
  const queries: Record<string, string> = {
    "/transactions": "transactions",
    "/reports/dre": "report",
    "/reports/cash-flow": "report",
    "/reports/detail": "report.detail",
    "/chart-of-accounts": "chart.accounts",
    "/bank-accounts": "bank.accounts",
    "/pending-items": "pending.items",
    "/bank-lines": "bank.lines",
    "/branches": "branches",
    "/settings": "settings",
  };
  if (method === "GET" && queries[path]) {
    return {
      query: true,
      action: queries[path],
      payload: path === "/reports/cash-flow"
        ? { ...params, basis: "cash" }
        : params,
    };
  }
  if (
    method === "GET" && (match = path.match(/^\/operations\/([^/]+)\/result$/))
  ) {
    return {
      query: true,
      action: "proposal.result",
      payload: { proposal_id: match[1] },
    };
  }
  if (
    method === "GET" && (match = path.match(/^\/proposals\/([^/]+)\/context$/))
  ) {
    return {
      query: true,
      action: "proposal.context",
      payload: { proposal_id: match[1] },
    };
  }
  if (
    method === "GET" && (match = path.match(/^\/products\/([^/]+)\/suppliers$/))
  ) {
    return {
      query: true,
      action: "product.suppliers",
      payload: { product_id: match[1] },
    };
  }
  if (method === "GET" && (match = path.match(/^\/exports\/([^/]+)$/))) {
    return { query: true, action: "export.job", payload: { job_id: match[1] } };
  }
  if (
    method === "GET" &&
    (match = path.match(/^\/bank-lines\/([^/]+)\/candidates$/))
  ) {
    return {
      query: true,
      action: "bank.candidates",
      payload: { ...params, line_id: match[1] },
    };
  }
  if (method === "GET" && (match = path.match(/^\/bank-imports\/([^/]+)$/))) {
    return {
      query: true,
      action: "bank.batch",
      payload: { batch_id: match[1] },
    };
  }
  if (
    method === "GET" &&
    (match = path.match(/^\/bank-imports\/([^/]+)\/status$/))
  ) return { query: true, action: "bank.job", payload: { batch_id: match[1] } };
  if (method === "GET" && (match = path.match(/^\/transactions\/([^/]+)$/))) {
    return {
      query: true,
      action: "transaction.detail",
      payload: { transaction_id: match[1] },
    };
  }
  if (
    method === "PATCH" &&
    (match = path.match(/^\/(chart-of-accounts|bank-accounts)\/([^/]+)$/))
  ) {
    return {
      query: false,
      action: match[1] === "bank-accounts" ? "bank.account.save" : "chart.save",
      payload: { ...body, id: match[2] },
    };
  }
  const commands: Record<string, string> = {
    "/suppliers/with-product-link": "supplier.link",
    "/transactions": "transaction.create",
    "/proposals": "proposal.save",
    "/bank-imports/preview": "bank.preview",
    "/settings": "settings.configure",
    "/exports": "export.create",
    "/chart-of-accounts": "chart.save",
    "/bank-accounts": "bank.account.save",
    "/prospects": "prospect.create",
  };
  if (method === "POST" && commands[path]) {
    return { query: false, action: commands[path], payload: body };
  }
  if (method === "PATCH" && (match = path.match(/^\/transactions\/([^/]+)$/))) {
    return {
      query: false,
      action: "transaction.patch",
      payload: { ...body, transaction_id: match[1] },
    };
  }
  const patterns: [RegExp, string, string][] = [
    [
      /^\/proposals\/([^/]+)\/transitions$/,
      "proposal.transition",
      "proposal_id",
    ],
    [/^\/bank-imports\/([^/]+)\/run$/, "bank.run", "batch_id"],
    [/^\/exports\/([^/]+)\/run$/, "export.run", "job_id"],
    [
      /^\/transactions\/([^/]+)\/legacy-review$/,
      "legacy.adopt",
      "transaction_id",
    ],
    [
      /^\/proposals\/([^/]+)\/financial-preview$/,
      "plan.preview",
      "proposal_id",
    ],
    [
      /^\/proposals\/([^/]+)\/cost-sale-review$/,
      "proposal.review",
      "proposal_id",
    ],
    [
      /^\/proposals\/([^/]+)\/cost-sale-review\/release$/,
      "proposal.review.release",
      "proposal_id",
    ],
    [
      /^\/transactions\/([^/]+)\/settlements$/,
      "settlement.create",
      "transaction_id",
    ],
    [
      /^\/transactions\/([^/]+)\/adjustments$/,
      "transaction.adjust",
      "transaction_id",
    ],
    [
      /^\/settlements\/([^/]+)\/corrections$/,
      "settlement.correct",
      "settlement_id",
    ],
    [/^\/bank-imports\/([^/]+)\/confirm$/, "bank.queue", "batch_id"],
    [/^\/bank-lines\/([^/]+)\/matches$/, "bank.match", "line_id"],
    [/^\/matches\/([^/]+)\/undo$/, "bank.undo", "match_id"],
  ];
  if (method === "POST") {
    for (const [pattern, action, key] of patterns) {
      if ((match = path.match(pattern))) {
        return { query: false, action, payload: { ...body, [key]: match[1] } };
      }
    }
  }
  if (
    method === "POST" &&
    /^\/proposals\/[^/]+\/financial-confirmation$/.test(path)
  ) {
    return {
      query: false,
      action: "plan.confirm",
      payload: { ...body, proposal_id: path.split("/")[2] },
    };
  }
  throw new Error("NOT_FOUND");
}

export function createHandler(
  config: Config,
): (request: Request) => Promise<Response> {
  const fetcher = config.fetch ?? fetch;
  return async (request) => {
    const requestId = crypto.randomUUID();
    const started = performance.now();
    const origin = request.headers.get("origin");
    const headers = new Headers({
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Request-ID": requestId,
      "Vary": "Origin",
    });
    if (origin && config.allowedOrigins.includes(origin)) {
      headers.set("Access-Control-Allow-Origin", origin);
      headers.set(
        "Access-Control-Allow-Headers",
        "authorization, apikey, content-type, idempotency-key",
      );
      headers.set("Access-Control-Allow-Methods", "GET, POST, PATCH, OPTIONS");
      headers.set(
        "Access-Control-Expose-Headers",
        "X-Request-ID, Retry-After, Content-Disposition",
      );
    }
    const respond = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers });
    const messages: Record<string, string> = {
      AUTH_REQUIRED: "Entre novamente para continuar.",
      MODULE_FORBIDDEN: "Seu acesso não permite esta operação.",
      RECORD_FORBIDDEN: "Você não tem acesso a este registro.",
      NOT_FOUND: "Registro não encontrado.",
      INVALID_REQUEST: "Revise os campos enviados.",
      VERSION_CONFLICT: "O registro mudou. Recarregue antes de continuar.",
      IDEMPOTENCY_CONFLICT: "Esta chave já identifica outra solicitação.",
      LEGACY_REVIEW_REQUIRED:
        "Revise e classifique o registro antigo antes de continuar.",
      ADJUSTMENT_REQUIRED: "A alteração exige revisão ou ajuste explícito.",
      DECISION_REQUIRED:
        "A política operacional precisa ser definida e registrada.",
      FINANCIAL_DATA_REQUIRED: "Complete as informações financeiras indicadas.",
      INVALID_TRANSITION: "Esta operação não é permitida no estado atual.",
      OVERLAP_REVIEW_REQUIRED: "Revise a possível sobreposição entre extratos.",
      UNSUPPORTED_MATCH_MODE:
        "Este modo de conciliação depende de uma política aprovada.",
      EXPORT_EXPIRED: "A exportação expirou. Solicite um novo arquivo.",
      EXPORT_NOT_READY: "A exportação ainda não está pronta.",
      PIPELINE_STAGE_REQUIRED: "Configure uma etapa para este segmento.",
      RATE_LIMITED: "Aguarde antes de repetir a solicitação.",
      PAYLOAD_TOO_LARGE: "O arquivo ou solicitação excede o limite permitido.",
      UNSUPPORTED_FILE: "Este formato de arquivo não é aceito.",
      TIMEOUT:
        "O prazo da operação foi excedido. Consulte o estado antes de repetir.",
    };
    const fail = (code: string, status?: number, retryable = false) => {
      if (code === "RATE_LIMITED") headers.set("Retry-After", "60");
      return respond({
        error: {
          code,
          message: messages[code] ?? "Não foi possível concluir a operação.",
          request_id: requestId,
          retryable,
        },
      }, status ?? errorStatuses[code] ?? 500);
    };
    try {
      if (origin && !config.allowedOrigins.includes(origin)) {
        return fail("MODULE_FORBIDDEN");
      }
      if (request.method === "OPTIONS") {
        return new Response(null, { status: 204, headers });
      }
      if (!["GET", "POST", "PATCH"].includes(request.method)) {
        return fail("INVALID_REQUEST", 405);
      }
      const key = request.headers.get("idempotency-key");
      if (
        request.method !== "GET" && (!key || key.length < 8 || key.length > 200)
      ) return fail("INVALID_REQUEST");
      if (!config.supabaseUrl || !config.anonKey) {
        return fail("DEPENDENCY_UNAVAILABLE");
      }
      const authorization = request.headers.get("authorization");
      if (!authorization?.match(/^Bearer\s+\S+$/i)) {
        return fail("AUTH_REQUIRED");
      }
      const signal = AbortSignal.timeout(config.timeoutMs ?? 15000);
      const upstreamHeaders = {
        apikey: config.anonKey,
        Authorization: authorization,
        "Content-Type": "application/json",
      };
      const auth = await fetcher(`${config.supabaseUrl}/auth/v1/user`, {
        headers: upstreamHeaders,
        signal,
      });
      if (!auth.ok) {
        return fail(
          auth.status >= 500 ? "DEPENDENCY_UNAVAILABLE" : "AUTH_REQUIRED",
        );
      }
      const user = await auth.json();
      if (!user?.id || typeof user.id !== "string") {
        return fail("AUTH_REQUIRED");
      }
      const url = new URL(request.url);
      const path =
        url.pathname.replace(/^.*\/finance-api\/v1(?=\/|$)/, "").replace(
          /^\/v1(?=\/|$)/,
          "",
        ) || "/";
      const download = request.method === "GET"
        ? path.match(/^\/exports\/([^/]+)\/download$/)
        : null;
      if (download) {
        const rpcQuery = async (
          action: string,
          payload: Json,
        ): Promise<Json> => {
          const response = await fetcher(
            `${config.supabaseUrl}/rest/v1/rpc/finance_query_v1`,
            {
              method: "POST",
              headers: upstreamHeaders,
              signal: AbortSignal.timeout(15000),
              body: JSON.stringify({ p_action: action, p_payload: payload }),
            },
          );
          const result = await response.json();
          if (!response.ok || result.error) {
            throw new Error(
              Object.hasOwn(
                  errorStatuses,
                  String(result?.message ?? "").split(":")[0],
                )
                ? String(result.message).split(":")[0]
                : result?.code === "42501"
                ? "MODULE_FORBIDDEN"
                : "NOT_FOUND",
            );
          }
          return result.data;
        };
        const job = await rpcQuery("export.job", { job_id: download[1] });
        if (job.state === "expired") return fail("EXPORT_EXPIRED");
        if (job.state !== "completed") return fail("EXPORT_NOT_READY");
        headers.set(
          "Content-Type",
          job.format === "csv"
            ? "text/csv; charset=utf-8"
            : "application/json; charset=utf-8",
        );
        headers.set(
          "Content-Disposition",
          `attachment; filename="atmos-finance-${download[1]}.${job.format}"`,
        );
        headers.set("X-Content-Type-Options", "nosniff");
        return new Response(
          downloadStream(job, async (part) =>
            (await rpcQuery("export.part", {
              job_id: download[1],
              part_number: part,
            })).rows as Json[]),
          { headers },
        );
      }
      let body: Json = {};
      if (request.method !== "GET") {
        const fileUpload = path === "/bank-imports/file-preview";
        if (fileUpload) {
          const check = await fetcher(
            `${config.supabaseUrl}/rest/v1/rpc/finance_query_v1`,
            {
              method: "POST",
              headers: upstreamHeaders,
              signal,
              body: JSON.stringify({
                p_action: "upload.authorize",
                p_payload: {},
              }),
            },
          );
          if (!check.ok) {
            const result = await check.json();
            return fail(
              result?.code === "P0429" ? "RATE_LIMITED" : "MODULE_FORBIDDEN",
            );
          }
        }
        const bytes = await limitedBody(
          request,
          fileUpload ? 10 * 1024 * 1024 : 1048576,
          signal,
        );
        if (fileUpload) {
          const name = url.searchParams.get("filename");
          const bank = url.searchParams.get("bank_account_id");
          if (!name || !bank) return fail("INVALID_REQUEST");
          const parsed = await parseStatement(bytes, name);
          if (signal.aborted) throw signal.reason;
          const hash = Array.from(
            new Uint8Array(
              await crypto.subtle.digest(
                "SHA-256",
                new Uint8Array(bytes).buffer,
              ),
            ),
          ).map((v) => v.toString(16).padStart(2, "0")).join("");
          body = {
            bank_account_id: bank,
            source_name: name,
            file_sha256: hash,
            rows: parsed.rows,
            parser_rejected: parsed.rejected,
          };
        } else {
          try {
            body = JSON.parse(new TextDecoder().decode(bytes));
          } catch {
            return fail("INVALID_REQUEST");
          }
          if (!body || Array.isArray(body) || typeof body !== "object") {
            return fail("INVALID_REQUEST");
          }
        }
      }
      const selected = path === "/bank-imports/file-preview"
        ? { query: false, action: "bank.preview", payload: body }
        : route(request.method, path, body, url.searchParams);
      const rpc = selected.action === "bank.run"
        ? "finance_bank_run_v1"
        : selected.action === "export.run"
        ? "finance_export_run_v1"
        : selected.query
        ? "finance_query_v1"
        : "finance_command_v1";
      const upstream = await fetcher(
        `${config.supabaseUrl}/rest/v1/rpc/${rpc}`,
        {
          method: "POST",
          headers: upstreamHeaders,
          signal,
          body: JSON.stringify(
            selected.action === "bank.run"
              ? { p_batch_id: selected.payload.batch_id }
              : selected.action === "export.run"
              ? { p_job_id: selected.payload.job_id }
              : {
                p_action: selected.action,
                p_payload: selected.payload,
                ...(selected.query ? {} : { p_idempotency_key: key }),
              },
          ),
        },
      );
      const result = await upstream.json();
      if (!upstream.ok) {
        const known = String(result?.message ?? "").split(":")[0];
        const code = Object.hasOwn(errorStatuses, known)
          ? known
          : result?.code === "P0429"
          ? "RATE_LIMITED"
          : result?.code === "42501"
          ? "MODULE_FORBIDDEN"
          : ["22023", "22P02"].includes(result?.code)
          ? "INVALID_REQUEST"
          : result?.code === "P0002"
          ? "NOT_FOUND"
          : "DEPENDENCY_UNAVAILABLE";
        if (code === "RATE_LIMITED") headers.set("Retry-After", "60");
        return fail(code);
      }
      if (result?.error) {
        return fail(
          result.error.code,
          undefined,
          result.error.retryable === true,
        );
      }
      if (selected.action === "bank.queue" && result?.data?.run_required) {
        const task = fetcher(
          `${config.supabaseUrl}/rest/v1/rpc/finance_bank_run_v1`,
          {
            method: "POST",
            headers: upstreamHeaders,
            signal: AbortSignal.timeout(60000),
            body: JSON.stringify({ p_batch_id: result.data.batch_id }),
          },
        ).then((r) => r.arrayBuffer()).catch(() => undefined);
        config.background?.(task);
      }
      if (selected.action === "export.create" && result?.data?.id) {
        const task = fetcher(
          `${config.supabaseUrl}/rest/v1/rpc/finance_export_run_v1`,
          {
            method: "POST",
            headers: upstreamHeaders,
            signal: AbortSignal.timeout(60000),
            body: JSON.stringify({ p_job_id: result.data.id }),
          },
        ).then((r) => r.arrayBuffer()).catch(() => undefined);
        config.background?.(task);
      }
      return respond({ ...result, request_id: requestId });
    } catch (error) {
      const code = error instanceof DOMException &&
          ["TimeoutError", "AbortError"].includes(error.name)
        ? "TIMEOUT"
        : error instanceof Error &&
            (Object.hasOwn(errorStatuses, error.message) ||
              /^(INVALID_|STATEMENT_|UNSUPPORTED_)/.test(error.message))
        ? Object.hasOwn(errorStatuses, error.message)
          ? error.message
          : "INVALID_REQUEST"
        : "INTERNAL_ERROR";
      // Log only classification and timing; never the URL, request body, JWT or upstream error text.
      console.error(
        JSON.stringify({
          request_id: requestId,
          code,
          duration_ms: Math.round(performance.now() - started),
        }),
      );
      return fail(code, undefined, code === "TIMEOUT");
    }
  };
}
