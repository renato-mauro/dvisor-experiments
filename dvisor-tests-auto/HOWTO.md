# Como executar

## Primeira vez

```bash
npm install
npm run setup   # instala Chromium
```

## Rodar experimentos

```bash
node run.js
```

Resultados salvos incrementalmente em `results/`. Re-executar pula o que já tem runs suficientes.

**Flags:**
```bash
node run.js --clear    # apaga resultados anteriores e recomeça
node run.js --dvisor   # só Dvisor
node run.js --duckdb   # só DuckDB
VERBOSE=simple node run.js  # mostra só a linha "done" de cada run
VERBOSE=1 node run.js       # mostra output frame a frame
```

Ao terminar, as tabelas são geradas automaticamente. Para regerá-las sem rodar experimentos:

```bash
node generate-tables.js
```

## Abrir resultados em figures.html

1. Abra `figures.html` no browser (deve estar rodando em `localhost:8080`)
2. Abra o console do browser (F12)
3. Cole o conteúdo de `results/import-to-localStorage.js`
4. A página recarrega com os novos resultados

## Arquivos de saída

| Arquivo | Conteúdo |
|---|---|
| `results/dvisor_results.json` | Resultados Dvisor (schema = localStorage) |
| `results/duckdb_results.json` | Resultados DuckDB (schema = localStorage) |
| `results/runs.csv` | Todos os runs individuais em CSV flat |
| `results/tables.tex` | Tabelas LaTeX (booktabs) |
| `results/tables.md` | Tabelas Markdown |
| `results/import-to-localStorage.js` | Script para carregar no browser |

## Configuração

Edite `experiment-config.json` para ajustar sources, SFs, threads e número de runs.
