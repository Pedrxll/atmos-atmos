# Handoff para Gustavo — backend financeiro Atmos v1

**Backend v1 implementado e validado localmente. Handoff gerado após concluir implementação e QA em 13/10/2026.** A próxima frente é integrar a interface, validar os casos reais e conduzir a publicação coordenada. Não houve alteração de produção, deploy, push ou chamada paga externa.

Base: `d8c57c2d7b2bc0b2a22f095b863fa1016a2eb6ba`, branch de implementação `codex/financeiro-backend`. O pacote de entrega informa o commit final, inclui patch contra essa base e cópias dos arquivos alterados. Compare com a versão atual do seu repositório antes de integrar.

## O que está pronto no backend

- 12 migrations com autorização, RLS, versões, idempotência, auditoria, snapshots e proteção de histórico.
- Cadastro de fornecedor a partir do produto, alternativas, executor negociado e revisão de custo/venda com conferência/liberação.
- Cálculo da proposta no SQL; preview de plano com pendências, condições/parcelas explícitas e confirmação que impede duplicação entre usuários/chaves.
- Títulos, baixas, saldo autoritativo, correções de registro, ajustes sem baixa, extras e resultado da operação.
- Plano de contas, contas bancárias, filtros/filiais, vencimento/competência/caixa, detalhe e export privado CSV/JSON em partes.
- Importação CSV/XLSX com rejeições rastreáveis, deduplicação/sobreposição, jobs, candidatos, conciliação exata 1:1 e undo sem gerar baixa.
- Endpoint financeiro autenticado e enriquecimento com falhas úteis; criação manual de prospect por segmento/etapa; contratos de aprovação pública/Clicksign preservados.
- Scripts, cenário fictício e evidências: 593 testes existentes, 24 Deno, 12 suítes SQL, percurso HTTP/matriz de módulos, negações diretas no PostgREST, concorrência, 100 mil títulos/200 mil eventos e restauração.

Leia nesta ordem: [API.md](API.md), [COBERTURA-FIN-DEP.md](COBERTURA-FIN-DEP.md), [REGRAS-FINANCEIRAS.md](REGRAS-FINANCEIRAS.md), [QA.md](QA.md), [MIGRACAO-E-OPERACAO.md](MIGRACAO-E-OPERACAO.md) e [DEMONSTRACAO.md](DEMONSTRACAO.md).

## Integração que Gustavo precisa completar

| Frente | Trabalho concreto | Critério de conclusão |
| --- | --- | --- |
| Transporte e sessão | Consumir `/functions/v1/finance-api/v1` com JWT; configurar origens exatas; chaves idempotentes estáveis por ação; tratar erro por code/request_id | Retry não duplica movimento e erro não aparece como lista vazia |
| Editor de proposta | Substituir RPC antigo pelo save v1; carregar contexto completo; enviar allowlist e composição completa; preservar IDs e expected_version | Salvar/reabrir mantém valores negociados; conflito pede recarga |
| Fornecedores | Cadastrar/selecionar pelo produto, listar alternativas e mostrar executor da proposta | Um mesmo fornecedor no cadastro/vínculo/obrigação; campos definidos com Lina |
| Conferência | Interface custo+venda, snapshot esperado, motivo e liberação explícita | Troca de identidade/hotel conferido não é silenciosa |
| Plano financeiro | Exibir origens, pendências, cronograma, preview/hash; confirmar apenas decisão/condições validadas | Uma obrigação por origem/parcela; nada gerado só por salvar rascunho |
| Receber/pagar | Baixas e correções pelos comandos; saldo/status do servidor; ajustes e conciliações com feedback | 1000+1500, correção e NF 000123 reproduzidos pela interface |
| Operação e relatórios | Mostrar previsto, extras, títulos, caixa e lacunas; plano de contas/filtros; export autenticado com job | Detalhe e total coerentes, sem somar orçamento com os próprios títulos |
| Bancos | Upload, rejeições/source_row, confirmação de sobreposição, status/retry_action, candidatos/match/undo | Repetir arquivo não duplica; desfazer vínculo não desfaz baixa |
| Dependências | Kanban manual, falhas do enriquecimento, hotel negociado e estados separados de aprovação/assinatura/sinal | Operador entende o próximo passo; nenhum sucesso vazio |

O contexto de leitura contém campos derivados/snapshots para conferência. Ao salvar, projete somente os campos aceitos no contrato; não envie todo o objeto de leitura por spread. Valores de títulos/baixas/relatórios são texto decimal e NF é texto. Não calcule saldo, pago ou principal autoritativo no cliente.

## Decisões e homologação da operação

Gustavo, Lina e contabilidade precisam fechar D01–D14 conforme a matriz de cobertura: marco/condições/comissões, cadastro obrigatório, parciais/ajustes, tarifa por dia, hotel simples, grupos, cancelamento/devolução, plano/layout, competência/fechamento, bancos/agrupamentos, capacidade/retenção/release e delegação.

O código inicia `manual_plan_confirmation`, `settlement_partials` e `unpaid_adjustments` desligados. Ative somente o que tiver decisão real, registrada pelo admin total em `/settings`. `automatic_generation` permanece desligada. Referências `SYNTHETIC` nos scripts valem apenas para a fixture. A v1 não habilita devolução real, juros/multa/desconto na baixa, adiantamento/crédito, tarifa por dia, grupo entre propostas ou conciliação agrupada sem especificação/implementação posterior da modalidade aprovada.

Homologar extratos reais e layout contábil, configuração/crédito da IA, provedor Clicksign e casos operacionais com o ambiente apropriado. A suíte local usou mocks para IA e não efetuou assinatura, pagamento ou emissão fiscal.

## Integração e publicação

**A migration 178000 exige rollout conjunto com o frontend v1.** Ela revoga CRUD financeiro/filhos e os RPCs antigos `save_proposal_bundle`, `save_proposal_cost_checks` e `generate_proposal_receivable`. Publicar apenas o SQL quebra telas que ainda chamam esses caminhos. A solução é completar a integração dos contratos; não restaurar grants para contornar a fronteira.

Executar o runbook em staging, revisar legado sem associar por descrição/preço, ensaiar backup/restore no destino, configurar jobs/retomada/limpeza de exports e monitorar falhas. O QA registra um advisory moderado transitivo e uma limitação do runtime PostgreSQL local; as evidências e o alcance estão descritos, sem ocultar achados. Obter autorização do responsável pelo ambiente antes de publicar e registrar o SHA final.

O aceite final de Lina deve demonstrar o percurso **produto/fornecedor → negociação/proposta → obrigações → baixas → resultado → contabilidade**, com interface integrada e dados fictícios identificados, seguido dos casos reais autorizados. DEP-05/WhatsApp permanece backlog de outra frente.
