# Migração e operação do backend financeiro v1

Esta entrega parte de `d8c57c2d7b2bc0b2a22f095b863fa1016a2eb6ba`. Nenhum script desta entrega publicou código ou alterou banco remoto. Os scripts em `backend/scripts` executam exclusivamente o projeto local `atmos_finance_backend`.

## Sequência de integração

1. Gustavo deve comparar a base atual do seu repositório com o SHA acima. Se houver evolução posterior, integrar a branch/patch e resolver os conflitos antes de aplicar SQL. As 12 migrations novas são uma sequência única, de `20261013170000` até `20261013181000`; não editar versões já aplicadas.
2. Criar staging isolado com a base histórica e dados sintéticos ou cópia autorizada e protegida. Fazer inventário dos títulos, chaves legadas, fornecedores órfãos, status pagos/cancelados e conciliações existentes. Uma migration não transforma um título legado em obrigação v1.
3. Aplicar a sequência nova em staging, publicar as funções `finance-api` e `enrich-prospect`, configurar origens e integrar o frontend. O parser da CLI 2.90.0 falhou em uma migration histórica multicomando; os scripts locais usam psql para reproduzir a base inteira. Em staging, usar o mecanismo de migrations validado pelo administrador e registrar versões/checksums; não copiar a tabela de controle local como substituto do histórico de produção.
4. Reproduzir SQL, percurso HTTP, perfis, imports/exports e confirmação de plano. Verificar também os webhooks e a aprovação pública com o ambiente externo de teste autorizado. A suíte local não fez chamada paga à IA nem assinatura real Clicksign.
5. Aprovar com Lina/contabilidade as decisões comerciais, as condições de pagamento, os formatos reais de banco e o layout contábil. Habilitar apenas capacidades aprovadas, pelo comando `/settings` com referência rastreável da decisão. As três políticas começam desligadas; geração automática permanece desligada.
6. Preparar backup e ensaio de restore no ambiente de destino; definir janela, responsável, retenção, metas e monitoramento. Só então executar o rollout coordenado com frontend v1 e migrations. Registrar a autorização e os SHAs efetivamente publicados.

## Quebra de compatibilidade que precisa de rollout conjunto

A migration `20261013178000` revoga o CRUD financeiro e dos filhos da proposta para `authenticated`, além de `save_proposal_bundle`, `save_proposal_cost_checks` e `generate_proposal_receivable`. O frontend antigo usa esses caminhos e precisa integrar os comandos v1 antes da publicação conjunta. Não reabrir grants para fazer uma tela antiga funcionar: isso remove a fronteira de versões, auditoria e idempotência.

Leituras autorizadas continuam disponíveis. Aprovação pública, assinatura Clicksign e sinal/baixa são eventos distintos. Os contratos de serviço de aprovação/Clicksign foram preservados e testados localmente; não geram títulos v1 de forma automática.

## Configuração de ambiente

| Item | Uso |
| --- | --- |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Disponibilizados no ambiente Edge. A função valida a sessão e encaminha o JWT do usuário ao PostgREST. |
| `FINANCE_ALLOWED_ORIGINS` | Origens exatas separadas por vírgula, incluindo protocolo e porta quando pertinente. Sem wildcard. |
| `LOVABLE_API_KEY` | Somente servidor, para enriquecimento. Ausência retorna indisponibilidade explícita. Não há evidência de crédito/configuração comercial do ambiente real. |
| `EdgeRuntime.waitUntil` | Mantém a execução de import/export em segundo plano. Jobs persistem estado e podem ser retomados pelos endpoints documentados. |
| Grants/RLS | Instalar pelas migrations. Nenhuma chave de serviço no navegador nem na função financeira. |

O `project_id` e as portas do `supabase/config.toml` desta branch destinam-se ao ambiente local. Conferir o vínculo do projeto de staging/produção no processo de release; não inferir o destino a partir dessas portas. Não publicar chaves, dumps ou arquivos `.env` junto do pacote.

## Legado e saneamento

Consultar pendências e revisar por título. `legacy-review` exige versão, motivo, datas explícitas e contraparte. Chave conhecida precisa ser mapeada para a origem correspondente; obrigação originalmente sem chave exige `independent_obligation:true`. Não associar por descrição, preço ou proximidade de data.

Pago exige evidência do pagamento histórico integral e conserva contraparte existente. O artefato reconhecido de comissão de hotel do RPC antigo admite reclassificação estreita por admin total, fornecedor/origem corretos e `decision_reference`, preservando o registro anterior. Cancelado só pode ser adotado com `preserve_cancelled:true` e decisão referenciada; continua cancelado. Cancelado com `paid_date` permanece bloqueado até revisão da política de caixa/cancelamento. Obrigações canceladas mapeadas não são reabertas por confirmar outro plano.

Backfill e validação de constraints históricas exigem relatório prévio de órfãos/duplicidades e aprovação sobre os registros reais. Não há seed de dados comerciais reais, conta contábil fictícia ou correção silenciosa nesta entrega.

## Retomada e monitoramento

- Falha de rede sem resultado confirmado: repetir o mesmo comando com a mesma chave e payload. Conflito de versão exige recarregar o agregado.
- Importação `queued`: `/run` retoma a tentativa. Importação `failed`: corrigir a causa e reenfileirar `/confirm` com nova chave; o status informa `retry_action`. Importação `confirmed` não se repete.
- Export `queued`: `/run` pelo proprietário com sessão atual. `failed`: criar novo job após corrigir a causa. Export completo é snapshot privado e expira em 24 horas; downloads revalidam autorização por parte.
- Monitorar jobs parados, `error_code`, 429, 503/504, duração, conflitos, volume e espaço das partes. Usar `request_id`; não registrar payload financeiro, documento, chave bancária ou JWT.
- `public.finance_export_cleanup_v1()` é uma rotina de serviço para remover partes expiradas. O administrador define agendamento/retenção e acompanha falhas. Não elimina história financeira nem auditoria.

Os limites de API, parser, plano e cota estão em [API.md](API.md). As medições locais em [QA.md](QA.md) são evidência do envelope sintético, não SLA de produção ou do provedor Edge.

## Backup, restore e retorno de versão

O ensaio local restaura o dump completo em outro banco fixo do mesmo cluster e compara totais, eventos, auditoria, exports, Auth, storage, ACL, RLS e extensões. A extensão `pg_cron` fica fora porque só instala no banco configurado no cluster; a origem sintética tem zero jobs. O wrapper GraphQL pertencente à extensão é reproduzido a partir da definição exata do banco de origem antes de restaurar seus grants. Isso não valida recuperação entre projetos/contas nem armazenamento externo de objetos.

Antes do rollout real, ensaiar o procedimento oficial de backup/restore do ambiente de destino, incluindo objetos, funções Edge, configuração, jobs, segredos e permissões, e medir RPO/RTO. O dump sintético local não é backup comercial.

Antes de qualquer escrita v1, o retorno pode usar o backup e a versão anterior conforme ensaio. Depois de haver baixas/auditoria v1, parar novos comandos e corrigir por migration incremental ou recuperação coordenada. Não apagar eventos, reabrir grants antigos ou executar `down` destrutivo para encobrir incompatibilidade. O responsável pelo release deve reconciliar os movimentos ocorridos na janela antes de retomar.
