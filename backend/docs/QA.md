# Validação final do backend financeiro v1 — 13/10/2026

**Resultado: implementação v1 validada no ambiente local isolado.** As 12 migrations instaladas correspondem exatamente aos SHA256 dos arquivos entregues. Não houve deploy, migration remota, pagamento real, emissão fiscal ou assinatura externa.

Ambiente observado no fechamento: macOS ARM, PostgreSQL 17.6/Supabase local, CLI 2.90.0, Deno 2.5.6, Node 26.7.0, Python 3.14.0 e psycopg 3.2.10. Referência de código: `d8c57c2d7b2bc0b2a22f095b863fa1016a2eb6ba`.

## Evidência executada

| Verificação | Resultado | Artefato |
| --- | --- | --- |
| Base histórica + 12 migrations novas, reconstruídas do zero | PASS; checksums instalados = fonte | `qa/migration-checksums.json` |
| Vitest existente | 70 arquivos / 593 testes PASS | `qa/unit-checks.json` |
| Deno | 24 testes PASS; typecheck, lint e formato PASS | `qa/unit-checks.json` |
| SQL financeiro e contratos preservados | 12 suítes PASS, fixtures em BEGIN/ROLLBACK | `qa/sql-regressions-result.json` |
| Percurso HTTP/Auth/PostgREST | 10 verificações integradas PASS; matriz com 8 perfis × 6 verificações | `qa/api-smoke-result.json` |
| Fronteira PostgREST direta | Anônimo sem RPC financeiro; admin sem RPC antigo/CRUD financeiro e bancário; 401/403 e banco saudável | `qa/boundary-http-result.json` |
| Concorrência | Três disputas com 20 sessões PASS, sem duplicação/excedente | `qa/load-concurrency-result.json` |
| Plano máximo | 200 origens, 500 títulos, 20 usuários; mesmo conjunto de obrigações | `qa/load-concurrency-result.json` |
| Carga/export | 100 mil títulos + 200 mil eventos adicionais; export de 200.004 linhas / 401 partes PASS | `qa/load-concurrency-result.json` |
| Restauração | Banco separado; contagens/totais, auditoria, partes, Auth/storage, ACL/RLS e extensões conferem | `qa/recovery-result.json` |

Os testes SQL preservados cobrem aprovação pública, Clicksign atômico/outbox, pipeline por segmento, privacidade de proposta, projeção pública do catálogo, portal do guia, cidade do prospect, autorização da equipe e sincronização de email. A sincronização usa agora o comando v1, pois o RPC antigo foi deliberadamente revogado. Os testes antigos que exigem sucesso de `save_proposal_bundle`, `save_proposal_cost_checks` ou `generate_proposal_receivable` não são declarados compatíveis: a quebra coordenada é exercitada pelos novos testes e pelo teste de fronteira HTTP.

O percurso de negócio HTTP cria fornecedor/vínculo, prospect/proposta, preserva negociação após mudança de catálogo, publica/aprova, confirma plano, registra baixas/correção/NF/extras, consulta relatórios, exporta, importa e concilia/desfaz. SQL no smoke se limita ao seed de referências/perfis e à mudança deliberada do catálogo, sem reparo da movimentação. O fornecedor B recebe a obrigação de 2.000; principal é 2.500; extras +50/−100 levam a 450 no vencimento, e caixa líquido no intervalo fica em 1.500.

## Medições da última execução

| Operação | p50 | p95 |
| --- | --- | --- |
| Lista de 200 títulos | 11,78 ms | 13,85 ms |
| Relatório por vencimento | 174,08 ms | 268,72 ms |
| Relatório por caixa | 363,97 ms | 525,56 ms |
| Confirmar plano máximo sob 20 usuários | 757,91 ms | 952,15 ms |

Lista/relatórios usam 10 amostras após aquecimento; o plano mede 20 chamadas concorrentes. Latências são do RPC de banco local com CPU compartilhada por outros testes, não de rede/Edge em produção. O CSV de 9.357.803 bytes/20 mil linhas levou 22,993 s do preview à importação confirmada. O restore do dump sintético de 23.989.211 bytes levou 5,18 s. As medições anteriores variaram; o JSON entregue conserva a última rodada completa, sem selecionar a mais rápida. Volume, metas operacionais e capacidade do plano Supabase real precisam ser homologados por Gustavo em staging.

## Revisão e correções

Revisões independentes dos blocos financeiro, banco/relatórios e API/proposta motivaram correções em duplicidade entre legado/v1, preservação de contraparte e referências históricas, versão/identidade, comissão, correção de baixa, parser ZIP/XLSX, posições de origem, autorização antes de processar arquivo, prazo de upload e jobs/retomada. A última leitura focada dos blocos financeiro e banco não encontrou P0/P1 concreto nos trechos revisados. Isso não é certificação universal de segurança ou aceite comercial.

As identidades de hotel incluem produto, fornecedor, datas, seleção, noites, caminho de pagamento e quartos. Snapshots de catálogo são capturados ao inserir/trocar produto e preservados nas demais edições. O contexto inclui os 19 campos editáveis da proposta e os dias; não inclui `share_token`. A checagem final comparou a allowlist de edição com os campos do contexto.

## Achados e limites registrados

- `deno audit` retorna **1 moderado, 0 alto, 0 crítico**: `exceljs > uuid`, GHSA-w5hq-g745-h8pq. O código ExcelJS 4.4.0 examinado chama somente `uuid.v4()` sem buffer externo. O advisory descreve o defeito nas APIs v3/v5/v6 e diferencia a validação de v4; a triagem indica que o caminho afetado não é usado neste fluxo, mantendo o achado registrado para manutenção da dependência. IDs próprios usam `crypto.randomUUID`/`gen_random_uuid`. Não há override fictício nem declaração de auditoria sem achados. [Advisory oficial](https://github.com/advisories/GHSA-w5hq-g745-h8pq), `qa/dependency-audit.txt` e `qa/uuid-reachability.txt`.
- O runtime PostgreSQL local 17.6 apresentou segfault em testes PL/pgSQL que alternam papel e chamam função revogada dentro de DO/exception. Os testes de privacidade, guia e equipe conferem o privilégio efetivo por `has_function_privilege`; o teste HTTP separado usa os argumentos corretos e verifica a rejeição real de chamadas ao PostgREST, com banco saudável depois. Os logs do incidente ficam somente no ambiente local. Revalidar a versão do runtime e os cenários de negação no destino; não inferir que o incidente foi corrigido no PostgreSQL.
- O teste de privacidade recebeu fornecedor sintético válido para atender à FK nova; as verificações de não exposição permanecem. O único arquivo alterado em `src/` é um teste de autorização para carregar o handler de enriquecimento extraído. Nenhum componente/tela do frontend foi implementado ou redesenhado.
- `pg_cron` é ligado ao banco configurado no cluster e foi excluído do restore isolado (19 entradas de TOC, zero jobs na origem). O wrapper GraphQL de bootstrap foi copiado da definição exata da origem antes dos grants. Todos os objetos financeiros/Auth/storage/auditoria permanecem no dump e nas comparações. Não é ensaio de desastre entre projetos nem backup de objetos externos.
- CSV grande foi exercitado pela API; XLSX foi exercitado nos testes de parsing/rejeição. Bancos e arquivos comerciais reais, Edge hospedado, IA paga, Clicksign real, layout/fechamento contábil e interface precisam de homologação própria.

## Reprodução

Siga [../README.md](../README.md), [DEMONSTRACAO.md](DEMONSTRACAO.md) e [MIGRACAO-E-OPERACAO.md](MIGRACAO-E-OPERACAO.md). Scripts recusam alvos remotos e não imprimem chaves. Recrie o runtime antes de repetir carga para manter o envelope de dados. A pasta `qa` contém somente resultados sanitizados, sem JWT, senha, dump ou logs de payload.
