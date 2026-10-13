# API financeira Atmos v1

Base em Supabase Edge: `/functions/v1/finance-api/v1`. Autenticação por `Authorization: Bearer <access_token>` da sessão Supabase; a API valida a sessão no Auth e encaminha o mesmo JWT ao banco. Não existe chave de serviço no cliente nem nesta função. Configure `FINANCE_ALLOWED_ORIGINS` com as origens exatas do frontend. Respostas e downloads usam `Cache-Control: no-store`.

Comandos exigem `Idempotency-Key` (8–200 caracteres). A chave é persistida por ator+ação, com hash do payload; repetição idêntica retorna o resultado anterior, enquanto outro payload retorna 409. Alterações exigem `expected_version` do agregado correspondente. Gere a chave uma vez por ação e conserve-a nos retries. Confirmações também são únicas pela origem/parcela, inclusive entre usuários/chaves diferentes.

Sucesso HTTP: `{data: ..., replayed?: boolean, request_id: UUID}`. Erro: `{error:{code,message,request_id,retryable}}`. Use o código para apresentar a ação necessária; nunca interprete erro como lista vazia. 409 de versão exige recarregar; retry de timeout sem resultado confirmado deve conservar a chave. Lote bancário já marcado `failed` exige corrigir a causa e usar nova chave no `/confirm`; consulte `retry_action`. Identificadores são UUID, datas civis são `YYYY-MM-DD`, valores financeiros de títulos/baixas/relatórios/exports são decimais textuais. Envie preços/custos como texto decimal; composição histórica de proposta preserva também campos JSON numéricos do contrato anterior, sem calcular dinheiro em ponto flutuante no cliente.

## Contratos de comandos

| HTTP | Corpo além do identificador no path | Permissão/resultado |
| --- | --- | --- |
| POST `/suppliers/with-product-link` | `product_id`; exatamente um de `supplier_id` ou `supplier:{name,cnpj?,contact_name?,phone?,email?,website?,pix_key?,bank_name?,bank_agency?,bank_account?,payment_terms?}`; `label?`, `reference_cost?`, `reference_sale?`, `payment_terms?`, `is_active?` | Cadastros. Criação+vínculo atômicos; documento já existente exige revisão. Retorna IDs. |
| POST `/proposals` | `proposal_id?`, `expected_version?`, `proposal`, `items`, `costs`, `days`, `accommodations` completos | Segmento antigo e novo. Cria/salva revisão negociada; total calculado no SQL; não cria títulos. |
| POST `/proposals/{id}/transitions` | `expected_version`, `operation:publish\|approve_manual`, `reason?` | Segmento; aprovação manual exige admin total e motivo. Publicação/aprovação não significam assinatura, sinal ou baixa. |
| POST `/proposals/{id}/cost-sale-review` | `expected_version`, `entity_kind:item\|accommodation`, `entity_id`, `expected_snapshot`, `unit_cost`+`unit_sale` para item, `rooms` para hotel, `reason` | Financeiro+segmento. Atualiza custo/venda e conferência/histórico atomicamente. Snapshot vem de `review_identity` do contexto. |
| POST `/proposals/{id}/cost-sale-review/release` | `expected_version`, `entity_kind`, `entity_id`, `reason` | Financeiro+segmento. Libera conferência preservando histórico, antes de mudar identidade/composição. |
| POST `/proposals/{id}/financial-preview` | `expected_version`, `conditions:[{origin,competence_date?,account_id?,installments:[{number,amount,due_date}]}]` | Financeiro. Retorna `preview_id`, `plan_hash`, `proposal_version`, `lines`, `pending_items`, `ready`. Não cria títulos. |
| POST `/proposals/{id}/financial-confirmation` | `preview_id`, `plan_hash`, `expected_version` | Financeiro; gate D01/D04, aprovação e pendências validados. Retorna IDs estáveis. Versão/hash antigos ou dívida alterada bloqueiam toda a operação. |
| POST `/transactions` | `type`, `description`, `amount`, `due_date`; `competence_date?`, `proposal_id?`, `supplier_id?`, `prospect_id?`, `seller_id?`, `counterparty_label?`, `account_id?`, `bank_account_id?`, `branch_id?`, `scope?`, `invoice_number?`, `notes?` | Financeiro. Contraparte necessária. Com proposta, escopo `operation`; sem proposta, `corporate` somente explícito ou `unclassified`. |
| PATCH `/transactions/{id}` | `expected_version`, `invoice_number?`, `competence_date?`, `account_id?`, `notes?` | Financeiro. Não aceita status/pago/saldo/credor/principal forjados. |
| POST `/transactions/{id}/settlements` | `expected_version` do título, `amount`, `effective_date`, `bank_account_id`, `payment_method`, `reference?` | Financeiro. Saldo autoritativo, sem excedente; parcial depende de política. Retorna evento, saldo, estado e versão. |
| POST `/settlements/{id}/corrections` | `expected_version` do título, `amount`, `reason` | Correção de registro referencia evento original e mantém sua data efetiva. Conciliação deve ser desfeita antes. Não representa devolução bancária. |
| POST `/transactions/{id}/adjustments` | `expected_version`, `amount?`, `due_date?`, `cancel?`, `reason` | Gate de ajustes sem baixa. Títulos com eventos/conciliação não podem mudar principal por este caminho. |
| POST `/transactions/{id}/legacy-review` | `expected_version`, `due_date`, `competence_date`, `reason`; contraparte/classificação/conta opcionais; `origin`+`installment_number`+`installment_total` para mapear; `independent_obligation:true` para obrigação independente originalmente sem chave | Financeiro. Não apaga chave conhecida. Pago exige evidência `historical_payment:{amount,effective_date,bank_account_id,payment_method,reference?}` e conserva contraparte existente. Hotel do RPC antigo aceita transformação estreita `mapped_type:commission_in`, `decision_reference`, admin total, fornecedor/origem corretos; preserva cliente antigo no histórico. Cancelado exige `preserve_cancelled:true`+`decision_reference` e continua cancelado; com paid_date bloqueia até decisão. |
| POST/PATCH `/chart-of-accounts[/{id}]` | `id?`, `expected_version?`, `code`, `name`, `type:income\|expense`, `parent_id?`, `is_active?`; PATCH pode omitir campos inalterados | Financeiro. Ciclos/código duplicado/natureza de conta usada bloqueados. Inative contas utilizadas. |
| POST/PATCH `/bank-accounts[/{id}]` | `id?`, `expected_version?`, `name`, `bank?`, `agency?`, `account_number?`, `account_type?`, `is_active?` | Financeiro. Projeções de leitura não retornam número/agência/Pix. |
| POST `/settings` | Um ou mais de `manual_plan_confirmation`, `settlement_partials`, `unpaid_adjustments`; `decision_reference` obrigatória | Admin total. Todos começam false; `automatic_generation` continua false e não é editável. Não habilitar com referência fictícia em produção. |
| POST `/prospects` | `segment`, `name`, `email?`, `phone?`, `company_name?`, `stage_id?`, `notes?` | Segmento. Usa etapa explicitamente escolhida ou primeira configurada daquele segmento. Sem etapa: `PIPELINE_STAGE_REQUIRED`. |
| POST `/exports` | `format:csv\|json`, `filters:{basis:due\|competence\|cash,from,to,proposal_id?}` | Financeiro. Cria job privado; execução disparada em segundo plano. |
| POST `/exports/{id}/run` | `{}` | Retomada idempotente pelo proprietário; exige JWT atual. |
| POST `/bank-imports/file-preview?filename=...&bank_account_id=...` | Bytes CSV/XLSX; `Idempotency-Key` | Financeiro e cota verificados antes do parser. Hash real dos bytes, linhas/rejeições de origem persistidas. |
| POST `/bank-imports/preview` | `bank_account_id,file_sha256,source_name,rows:[{source_row?,date,amount,direction,description?,external_id?}],parser_rejected?` | Entrada JSON normalizada autorizada. Hash informado é identidade de deduplicação; utilize o endpoint de arquivo para hash calculado no servidor. |
| POST `/bank-imports/{id}/confirm` | `acknowledge_overlaps?` | Enfileira importação atômica e dispara job. Leia `/status`; possível sobreposição sem ID exige confirmação explícita. |
| POST `/bank-imports/{id}/run` | `{}` | Retoma lote queued; autorização financeira revalidada. |
| POST `/bank-lines/{id}/matches` | `expected_version` da linha, `allocations:[{transaction_id,settlement_id?,amount}]` | Somente 1:1 exato de direção/valor/conta; legado exige adoção. Grupo devolve `UNSUPPORTED_MATCH_MODE`. Não cria baixa. |
| POST `/matches/{id}/undo` | `reason` | Preserva vínculo desfeito e libera evidência para nova conferência. Não desfaz pagamento. |

A composição de proposta rejeita campos derivados/privilegiados. Campos de `proposal`: title,segment,prospect_id,seller_id,guide_id,discount_percent,discount_fixed,tax_percent,notes,valid_until,num_people,num_days,start_date,end_date,language,atmos_service,slug,payment_terms,show_price_breakdown. Itens exigem day_number,item_index,category,value,cost_price,commission_percent,quantity; IDs, catálogo, variação, fornecedor, veículo, horários e descrição são opcionais. Custos: id?,description,amount,account_id?,supplier_id?. Dias: id?,day_number,description?. Hospedagens: id?,product_id,supplier_id?,num_nights,checkin_date?,checkout_date?,notes?,is_selected,payment_type,rooms. Use IDs retornados em `child_ids` para preservar identidade nas próximas revisões.

`atmos_service`: price_per_person_day,description?,num_courtesies?,seller_commission_percent?,internal_costs?. Custos internos precisam de ID estável, amount e beneficiário real para gerar obrigação; sem esse mapeamento o preview apresenta pendência. Quartos preservam unidades/modalidades/capacidade/noites/preço/custo/comissão do snapshot; ausência de comissão histórica não é preenchida pelo catálogo.

## Leituras

| GET | Parâmetros/resposta |
| --- | --- |
| `/proposals/{id}/context` | Composição autorizada completa, campos editáveis da proposta, dias, versões, itens/hospedagens e `review_identity`; sem share_token. Financeiro ou segmento autorizado. |
| `/operations/{id}/result` | Previsto da proposta, extras independentes, previsão com extras, títulos/caixa em toda a operação, abertos, pendências e origens. Para período/base use relatórios. |
| `/transactions` | limit 1..200,cursorUUID,type,status,proposal_id,supplier_id,prospect_id,seller_id,account_id,bank_account_id,branch_id,scope,overdueBoolean,from,to. `{rows,next_cursor}`. |
| `/transactions/{id}` | Título, eventos e histórico de ajustes; nenhuma alteração por GET. |
| `/chart-of-accounts`, `/bank-accounts`, `/branches`, `/products/{id}/suppliers` | limit/cursor; `{rows,next_cursor}`. Filial permanece cadastro do mesmo negócio; não é tenant. |
| `/reports/dre` | basis obrigatória: due/competence/cash; from,to,proposal_id?. Totais por conta, completude e pendências. Gerencial; plano/fechamento precisam de aceite contábil. |
| `/reports/cash-flow` | from,to,proposal_id?; base cash fixada pela rota. Somente eventos líquidos na data efetiva. |
| `/reports/detail` | mesmos filtros+basis,limit,cursor. Soma do detalhe corresponde à base do relatório. |
| `/pending-items`, `/settings` | Lacunas agregadas/configuração; não incluir dados pessoais em logs. |
| `/exports/{id}` | Estado queued/completed/failed/expired, snapshot/filtros/contagem/partes/totais. Somente criador com módulo financeiro. |
| `/exports/{id}/download` | Fetch autenticado; CSV UTF-8 ou JSON streaming. Sem URL pública. 24h de validade técnica; revalida autorização/expiração por parte. |
| `/bank-imports/{id}` | Preview persistido: aceitas/rejeitadas/source_row/hash/sobreposição. |
| `/bank-imports/{id}/status` | Estado, attempt, aceitas/rejeitadas/importadas/duplicadas, error_code, can_retry, retry_action (`run` quando queued; `confirm_with_new_key` quando failed). Progresso por fase; importação é atômica. |
| `/bank-lines` | bank_account_id,status,from,to,limit,cursor; linhas+histórico de vínculos. |
| `/bank-lines/{id}/candidates` | Sugestões até 200 com explicação e diferença de datas; nenhuma conciliação automática. |

## Limites e erros operacionais

JSON 1 MiB; arquivo 10 MiB; normalização bancária 16 MiB; 20 mil registros por lote; CSV até 100 colunas/10 mil caracteres por campo; XLSX somente uma planilha, sem macros/fórmulas/DTD/entidades, até 200mil células/120 mil strings, 20 MiB por entrada ZIP/50 MiB expandido, 1000 entradas e limites de compressão. Unidades monetárias até 8 casas antes de multiplicar; títulos/baixas até 2 casas e abaixo de 100 milhões. Até 200 condições, 500 títulos por plano e 100 parcelas por origem. Sem truncamento silencioso. Arquivos/casos de banco reais ainda exigem homologação D12.

Cotas por usuário/minuto: 60 comandos, 120 leituras, 5 pré-processamentos de arquivo, 5 criações de export, 10 execuções de export/import, 1000 partes de download. Jobs não exigem service_role: usam o JWT do solicitante e podem ser retomados pelos endpoints `/run`; produção precisa habilitar o mecanismo `EdgeRuntime.waitUntil` e monitorar filas/erros. Limites interativos e de job são distintos; falha/transação perdida pode deixar queued, que é retomável e nunca é apresentada como importação concluída.

401 sessão; 403 módulo/registro ; 404 inexistente ou export de outro dono ; 409 versão/idempotência/legado/ajuste/sobreposição ; 410 export expirado ; 422 dados/política/transição/modo de conciliação ; 429 cota com Retry-After ; 503 dependência ; 504 timeout. Não repetir ajuste/version conflict às cegas.
