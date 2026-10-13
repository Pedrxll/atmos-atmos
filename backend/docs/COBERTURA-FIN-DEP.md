# Cobertura das necessidades de Lina

O backend implementa os contratos abaixo. A validação funcional pela interface e o aceite das regras reais continuam com Gustavo, Lina e a contabilidade. Evidências reproduzíveis estão em [QA.md](QA.md); o inventário de fórmulas está em [REGRAS-FINANCEIRAS.md](REGRAS-FINANCEIRAS.md).

| Necessidade | Implementação entregue | Evidência principal | O que Gustavo completa |
| --- | --- | --- | --- |
| FIN-01 — inventário | Regras, fontes, exemplos, precisão, ordem e decisões registradas | Inventário + 593 testes existentes + cálculo SQL/HTTP | Revisar exemplos com Lina; distinguir regra comercial de defeito |
| FIN-02 — produto/fornecedor | Criar/selecionar fornecedor e vincular ao produto atomicamente; documento normalizado; alternativas paginadas | API smoke; `finance_v1_core` | Fluxo de cadastro na interface e campos reais obrigatórios |
| FIN-03 — executor alternativo | Vínculo múltiplo e fornecedor escolhido no snapshot; obrigação dirigida ao executor | Core/operations; percurso fornecedor B | Seleção visível, negociação e regras de troca após pagamento |
| FIN-04 — valores negociados | Save v1 com cálculo SQL, versões, catálogo de referência preservado e composição completa; sem reprecificar pelo catálogo atual | Operations; API salva/altera catálogo/reabre | Integrar editor com IDs estáveis, versões e contrato completo |
| FIN-05 — custo/venda | Revisão atômica com identidade, conflito, autor/motivo, histórico e liberação; hotel inclui datas/seleção/composição | Operations; guards/core | Tela de conferência e feedback de conflito/liberação; delegação D14 |
| FIN-06 — obrigações | Preview/hash/pendências/parcelas/datas explícitas; confirmação idempotente por origem; geração automática desligada | Core; HTTP; 20 sessões; plano máximo | Marco/condições reais D01/D02/D04 e interface de preview/confirmar |
| FIN-07 — hotel/comissão | Caminhos Atmos/direto; principal, custo e comissão separados; quartos negociados sem depender de unidades atuais; legado revisado | Core/operations/safety; origem e cancelamento | Caso real sem unidades D07; validar base/pagador/marco de comissão |
| FIN-08 — receber/pagar | Eventos de baixa, saldo, correção referenciada; NF textual; ajustes sem baixa com gate; proíbe excedente | Core; HTTP 1000+1500/correção; concorrência | Rotina operacional, políticas de parciais/ajustes; devoluções e agrupamentos pendem de decisão |
| FIN-09 — resultado | Previsto, extras, títulos, caixa, abertos e incompletude; operação versus corporativo explícito e não classificado | Resultado 500+50−100=450; SQL/HTTP | Visualização/explicação, definição de grupo independente D08 |
| FIN-10 — contabilidade | Plano hierárquico, filtros/filial, bases vencimento/competência/caixa, detalhe coerente, CSV/JSON privado em partes | Safety; exports HTTP; 200 mil eventos/export; NF 000123 | Contas/layout/datas/fechamento e aceite contábil D10/D11 |
| FIN-11 — conciliação | CSV/XLSX, rejeições/source_row/hash, dedup, sobreposição, job, candidatos, vínculo 1:1, undo sem baixa | 24 testes Deno; core; HTTP 20 mil linhas | Extratos reais, revisão de sobreposição, UX e formatos/taxas/grupos D12 |
| FIN-12 — demonstração | Script do percurso real HTTP/Auth/PostgREST e cenário sintético documentado | `api-smoke.py`, [DEMONSTRACAO.md](DEMONSTRACAO.md) | Reproduzir pela interface, orientar Lina e obter aceite |
| DEP-01 — prospect/etapa | Criação manual por segmento com etapa configurada; erro útil quando ausente | Core/HTTP; pipeline e sync de email SQL | Reproduzir Kanban e exibir pendência de configuração |
| DEP-02 — enriquecimento | Auth antes do gateway; configuração, timeout, 402/429/JSON/resultado inválido tipados; dados exigem revisão | 3 testes Deno e regressão de autorização existente | Configuração/crédito real e feedback; chamada paga/homologação separada |
| DEP-03 — hotel simples | Composição negociada mantém modalidades, capacidade, unidades, noites e valores, sem buscar unidades no catálogo | Operations; inventário de hospedagem | Confirmar com Lina o caso real D07 e integrar formulário |
| DEP-04 — aprovação/assinatura | Aprovação v1 explícita e contratos públicos/Clicksign preservados; sem confundir assinatura/sinal/baixa | `approve_proposal_atomic`, `clicksign_webhook_atomic`; 593 testes | Homologação externa autorizada e marco financeiro real D01/D04 |
| DEP-05 — WhatsApp | Registrado como backlog posterior, sem dependência no percurso financeiro | Escopo original e demonstração | Priorizar em outra frente |

## Decisões que permanecem explícitas

D01 marco de geração; D02 cronograma; D03 campos/duplicidades de fornecedores; D04 comissões; D05 parciais/excedente/taxas; D06 tarifa Atmos por dia; D07 hotel sem unidades; D08 grupos; D09 cancelamento/devolução; D10 plano/layout contábil; D11 reconhecimento/fechamento; D12 bancos/agrupamentos; D13 ambiente, capacidade, retenção e release; D14 delegação.

O backend oferece o modo manual exato, as capacidades testadas e bloqueios tipados para essas fronteiras. Não há regra comercial inventada para contornar decisão ausente. Tarifas diferentes por dia, grupo entre propostas, devolução bancária, juros/multa/desconto na baixa, adiantamento/crédito e conciliação agrupada não estão habilitados nesta versão.
