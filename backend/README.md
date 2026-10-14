# Atmos backend financeiro v1

Implementação local na branch `codex/financeiro-backend`, baseada em `d8c57c2d7b2bc0b2a22f095b863fa1016a2eb6ba` (`codex/atmos-stabilization`). Backend em SQL/PostgreSQL+Supabase Edge/Deno. O frontend recebe contratos v1 e precisa integrar os comandos antes do cutover. Nenhuma migration/deploy/dado de produção foi alterado.

Entrega publicada em 14/10/2026: [PR #1 no repositório original](https://github.com/linaheimpelcontato-ui/atmos-atmos/pull/1), em draft, via fork, com destino à base `codex/atmos-stabilization`. O backend continua aguardando integração da interface e homologação do ambiente real.

- [API e contratos](docs/API.md)
- [Regras preservadas e decisões](docs/REGRAS-FINANCEIRAS.md)
- Migrations: `supabase/migrations/2026101317*.sql` e `2026101318*.sql`, em ordem lexicográfica.
- Entrypoints: `supabase/functions/finance-api`, `supabase/functions/enrich-prospect`.
- Testes SQL: `supabase/tests/finance_v1_*.sql`; testes Deno: `supabase/functions/finance-api/tests`.
- [Handoff final para Gustavo](docs/HANDOFF-GUSTAVO.md)
- [QA e evidências](docs/QA.md), [cobertura FIN/DEP](docs/COBERTURA-FIN-DEP.md), [migração/operação](docs/MIGRACAO-E-OPERACAO.md) e [demonstração](docs/DEMONSTRACAO.md).

## Ambiente isolado

Requisitos observados: Docker Desktop, Supabase CLI 2.90.0, PostgreSQL 17.6, Deno 2.5.6, Node 26.7.0/npm, Python 3.14.0. O runtime é criado vazio em `backend/.local/runtime`; o SQL histórico é aplicado por psql/simple-query porque a CLI 2.90 falha no parser de uma migration existente. Scripts de banco aceitam somente este container/projeto local; não aceitam URL remota.

```sh
python3 backend/scripts/start-local.py
# Recriação destrutiva APENAS do ambiente sintético deste projeto:
python3 backend/scripts/rebuild-local.py

npm ci
deno task --config supabase/functions/finance-api/deno.json check
deno task --config supabase/functions/finance-api/deno.json test
NODE_OPTIONS=--no-experimental-webstorage npm test
python3 backend/scripts/sql-regressions-local.py
python3 backend/scripts/api-smoke.py
python3 backend/scripts/boundary-http-local.py
python3 -m venv backend/.venv
backend/.venv/bin/pip install -r backend/requirements-dev.txt
backend/.venv/bin/python backend/scripts/load-concurrency.py
```

API da stack local 55321, PostgreSQL 55322; o servidor de teste HTTP 55280 só é criado durante api-smoke.py. Não gere/compartilhe `.env` com tokens. Os scripts capturam as chaves locais em memória e relatam somente resultados sintéticos. `backend/.local`, `.venv`, node_modules, dumps e logs não fazem parte da entrega.

Para cada teste SQL, execute psql com ON_ERROR_STOP=1 no container `supabase_db_atmos_finance_backend`; fixtures usam BEGIN/ROLLBACK. Load/API smoke criam dados exclusivamente sintéticos no banco descartável. Refaça o runtime antes de repetir carga para manter o envelope de 100 mil títulos/200 mil eventos adicionais.

No runtime Node observado, o flag de teste acima evita conflito entre WebStorage experimental e jsdom. O ajuste em src/test/adminModuleEdges.test.ts carrega o handler de enriquecimento extraído; não modifica comportamento do frontend.
