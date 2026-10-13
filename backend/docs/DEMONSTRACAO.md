# Demonstração reproduzível do backend

Execute na raiz do repositório seguindo [../README.md](../README.md). O alvo é exclusivamente local e sintético. O script usa Auth real e chamadas HTTP para toda a movimentação de negócio; SQL se limita ao seed de referências/perfis e à mudança deliberada do catálogo para verificar preservação. Não há reparo SQL do percurso.

```sh
python3 backend/scripts/start-local.py
python3 backend/scripts/sql-regressions-local.py
python3 backend/scripts/api-smoke.py
```

Para repetir carga ou recomeçar a fixture, use `rebuild-local.py` antes. Ele apaga somente o runtime isolado desta tarefa. Não use os scripts com dados reais.

| Passo | Ação | Resultado a conferir |
| --- | --- | --- |
| 1 | Autenticar admin sintético e usuário sem módulo financeiro | Admin executa; usuário sem módulo recebe 403 |
| 2 | Criar conta, banco, fornecedor B pelo produto; repetir chave | Mesmo fornecedor/vínculo; sem duplicação |
| 3 | Criar prospect manual e proposta com transfer de 2.500 e custo 2.000 | Etapa configurada, executor B, total SQL de 2.500 |
| 4 | Alterar preço de referência do catálogo e reabrir proposta | Negociação de 2.500/2.000 preservada |
| 5 | Publicar/aprovar manualmente na fixture, preparar cronograma e confirmar | Preview explícito e exatamente dois títulos; repetir com outra chave retorna os mesmos IDs |
| 6 | Baixar 1.000 em novembro e 1.500 em dezembro; corrigir a primeira baixa | Saldos 1.500 → 0 → 1.000; correção conserva data de novembro |
| 7 | Gravar NF `000123`; adicionar receita extra 50 e custo extra 100 | Resultado por vencimento 450; caixa efetivo líquido 1.500 no intervalo dos dois meses |
| 8 | Exportar CSV/JSON e tentar acesso sem módulo ou por outro dono | Dados/totais coerentes, NF textual; acesso privado |
| 9 | Importar CSV com 31/02 inválido e duas linhas iguais legítimas | Rejeição preservada; três linhas aceitas com posição original; nenhuma linha legítima perdida |
| 10 | Conciliar linha com baixa existente e desfazer | Evidência de match/undo; nenhuma nova baixa |
| 11 | Testar sete módulos individuais e perfil com todos os sete | Permissões de lista/contexto/cadastro/export/configuração conforme matriz |
| 12 | Pré-processar/importar CSV com 20 mil linhas e cerca de 9,36 MB | Job termina `confirmed`, contagem persistida e tempo relatado |

O script registra políticas com referência `SYNTHETIC HTTP FIXTURE ONLY`. Essa configuração é exclusiva do banco descartável e não serve como autorização comercial. Cenários adicionais de revisão de custo/venda, hospedagem, legado, cancelamento, export em múltiplas partes e conflitos estão nas três suítes SQL financeiras.

Para a demonstração de Lina, Gustavo deve reproduzir os passos pela interface integrada, exibir pendências e distinguir previsto, títulos e caixa. Usar nomes/valores fictícios identificados e não efetuar pagamento, emissão fiscal ou assinatura real durante esse roteiro.
