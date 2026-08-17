#!/usr/bin/env node
'use strict';

/**
 * Dvisor automated benchmark runner.
 *
 * Usage:
 *   node run.js               — run all experiments per experiment-config.json
 *   node run.js --clear       — clear existing results first
 *   node run.js --dvisor      — run only Dvisor experiments
 *   node run.js --duckdb      — run only DuckDB experiments
 *   node run.js --help        — show this help
 *
 * Environment:
 *   VERBOSE=simple  — print only the final "done" line from each run
 *   VERBOSE=1       — print all browser console messages (frame by frame)
 *
 * Results are saved incrementally to results/ after each run.
 * Re-running the script skips combinations that already have enough runs.
 */

const { chromium }  = require('playwright');
const http          = require('node:http');
const fs            = require('node:fs');
const path          = require('node:path');

// ── Parse flags ──────────────────────────────────────────────────────────────
const args       = process.argv.slice(2);
const CLEAR      = args.includes('--clear');
const ONLY_DV    = args.includes('--dvisor');
const ONLY_DK    = args.includes('--duckdb');
const CONFIG_ARG = args.find(a => a.startsWith('--config='));

// ── Paths ────────────────────────────────────────────────────────────────────
const DIR         = __dirname;
const RUNNER_DIR  = path.join(DIR, 'runner');
const RESULTS_DIR = path.join(DIR, 'results');
const CONFIG_FILE = CONFIG_ARG
  ? path.resolve(DIR, CONFIG_ARG.slice('--config='.length))
  : path.join(DIR, 'experiment-config.json');

const DVISOR_JSON = path.join(RESULTS_DIR, 'dvisor_results.json');
const DUCKDB_JSON = path.join(RESULTS_DIR, 'duckdb_results.json');
const RUNS_CSV    = path.join(RESULTS_DIR, 'runs.csv');
const VERBOSE_FULL   = process.env.VERBOSE === '1';
const VERBOSE_SIMPLE = process.env.VERBOSE === 'simple' || VERBOSE_FULL;

if (args.includes('--help')) {
  console.log(`
Usage: node run.js [options]
  --clear    Clear existing results before running
  --dvisor   Run only Dvisor experiments
  --duckdb   Run only DuckDB experiments
  --help     Show this help

Environment:
  VERBOSE=simple  Print only the final "done" line from each run
  VERBOSE=1       Print all browser console messages (frame by frame)
`);
  process.exit(0);
}

// ── Config ───────────────────────────────────────────────────────────────────
const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));

// ── Setup results dir ────────────────────────────────────────────────────────
fs.mkdirSync(RESULTS_DIR, { recursive: true });

if (CLEAR) {
  [DVISOR_JSON, DUCKDB_JSON, RUNS_CSV].forEach(f => {
    if (fs.existsSync(f)) { fs.unlinkSync(f); console.log('cleared', f); }
  });
}

// ── Load / init result stores ────────────────────────────────────────────────
function loadJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return {}; }
}

let dvisorData = loadJSON(DVISOR_JSON);
let duckdbData = loadJSON(DUCKDB_JSON);

// ── CSV helper ───────────────────────────────────────────────────────────────
let csvReady = fs.existsSync(RUNS_CSV);

function appendCSVRow(fields) {
  if (!csvReady) {
    fs.writeFileSync(RUNS_CSV, 'engine,source,threads,query,sf,run_index,ttf_ms,tq_ms,rows,frames,ts\n');
    csvReady = true;
  }
  fs.appendFileSync(RUNS_CSV, fields.join(',') + '\n');
}

// ── Nested object helpers ────────────────────────────────────────────────────
function deepGet(obj, keys) {
  return keys.reduce((cur, k) => cur?.[k], obj);
}

function deepPush(obj, keys, value) {
  let cur = obj;
  for (let i = 0; i < keys.length - 1; i++) {
    cur[keys[i]] ??= {};
    cur = cur[keys[i]];
  }
  const last = keys[keys.length - 1];
  cur[last] ??= [];
  cur[last].push(value);
}

// ── Static file server ───────────────────────────────────────────────────────
const MIME = {
  html: 'text/html; charset=utf-8',
  js:   'application/javascript; charset=utf-8',
  mjs:  'application/javascript; charset=utf-8',
  css:  'text/css',
  wasm: 'application/wasm',
};

function startServer(dir, port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const urlPath  = new URL(req.url, `http://localhost:${port}`).pathname;
      const filePath = path.join(dir, urlPath === '/' ? 'index.html' : urlPath);
      const resolved = path.resolve(filePath);

      if (!resolved.startsWith(path.resolve(dir))) {
        res.writeHead(403); res.end('Forbidden'); return;
      }

      fs.readFile(resolved, (err, data) => {
        if (err) { res.writeHead(404); res.end('Not Found'); return; }
        const ext = path.extname(resolved).slice(1).toLowerCase();
        res.writeHead(200, {
          'Content-Type':                MIME[ext] || 'application/octet-stream',
          'Access-Control-Allow-Origin': '*',
        });
        res.end(data);
      });
    });

    server.on('error', reject);
    server.listen(port, () => {
      console.log(`Static server → http://localhost:${port}`);
      resolve(server);
    });
  });
}

// ── Run a single query in Playwright ─────────────────────────────────────────
async function runOne(browser, engine, { source, threads, query, sf }) {
  const { serverPort } = config;

  const qs = engine === 'dvisor'
    ? `source=${source}&threads=${threads}&query=${query}&sf=${sf}`
    : `source=${source}&query=${query}&sf=${sf}`;

  const url = `http://localhost:${serverPort}/${engine}-runner.html?${qs}`;

  const context = await browser.newContext({ serviceWorkers: 'block' });
  context.setDefaultTimeout(0);
  context.setDefaultNavigationTimeout(0);
  const page = await context.newPage();

  page.on('console', msg => {
    const txt = msg.text();
    if (msg.type() === 'error') {
      console.error(`  [browser:err] ${txt}`);
    } else if (VERBOSE_FULL) {
      console.log(`  [browser] ${txt}`);
    } else if (VERBOSE_SIMPLE && txt.includes('done ·')) {
      console.log(`  [browser] ${txt}`);
    }
  });

  page.on('pageerror', err => {
    console.error(`  [page error] ${err.message}`);
  });

  try {
    await page.goto(url, { timeout: 0 });
    await page.waitForFunction(() => window.__done === true, { timeout: 0 });

    const result = await page.evaluate(() => window.__result);
    const error  = await page.evaluate(() => window.__error);

    if (error) throw new Error(error);
    return result;
  } finally {
    await page.close();
    await context.close();
  }
}

// ── Dvisor experiment loop ────────────────────────────────────────────────────
async function runDvisor(browser) {
  console.log('\n══ Dvisor ══════════════════════════════');

  const { sources, queries, scalefactors } = config;
  const { threads: threadsList, runsPerCombination } = config.dvisor;

  for (const source of sources) {
    for (const threads of threadsList) {
      for (const query of queries) {
        for (const sf of scalefactors) {
          const keys   = [source, String(threads), query, String(sf)];
          const runs   = deepGet(dvisorData, keys) || [];
          const needed = runsPerCombination - runs.length;

          if (needed <= 0) {
            console.log(`  skip  dvisor ${source} ${threads}T ${query} SF=${sf} (${runs.length}/${runsPerCombination} runs)`);
            continue;
          }

          for (let i = runs.length; i < runsPerCombination; i++) {
            const tag = `dvisor ${source} ${threads}T ${query} SF=${sf} [${i + 1}/${runsPerCombination}]`;
            console.log(`  →  ${tag}`);

            try {
              const result = await runOne(browser, 'dvisor', { source, threads, query, sf });

              if (result?.skipped) {
                console.log(`     skipped`);
                break;
              }

              console.log(`     tq=${(result.tq / 1000).toFixed(2)}s  ttf=${(result.ttf / 1000).toFixed(2)}s  rows=${result.rows}  frames=${result.frames}`);

              const record = { ttf: result.ttf, tq: result.tq, rows: result.rows, frames: result.frames, ts: result.ts || Date.now() };
              deepPush(dvisorData, keys, record);
              fs.writeFileSync(DVISOR_JSON, JSON.stringify(dvisorData, null, 2));

              appendCSVRow(['dvisor', source, threads, query, sf, i + 1, result.ttf, result.tq, result.rows, result.frames, record.ts]);

            } catch (err) {
              console.error(`     ERROR: ${err.message}`);
            }
          }
        }
      }
    }
  }
}

// ── DuckDB experiment loop ────────────────────────────────────────────────────
async function runDuckDB(browser) {
  console.log('\n══ DuckDB ══════════════════════════════');

  const { sources, queries, scalefactors } = config;
  const { runsPerCombination } = config.duckdb;

  for (const source of sources) {
    for (const query of queries) {
      for (const sf of scalefactors) {
        const keys   = [source, query, String(sf)];
        const runs   = deepGet(duckdbData, keys) || [];
        const needed = runsPerCombination - runs.length;

        if (needed <= 0) {
          console.log(`  skip  duckdb ${source} ${query} SF=${sf} (${runs.length}/${runsPerCombination} runs)`);
          continue;
        }

        for (let i = runs.length; i < runsPerCombination; i++) {
          const tag = `duckdb ${source} ${query} SF=${sf} [${i + 1}/${runsPerCombination}]`;
          console.log(`  →  ${tag}`);

          try {
            const result = await runOne(browser, 'duck', { source, query, sf });

            if (result?.skipped) {
              console.log(`     skipped`);
              break;
            }

            console.log(`     tq=${(result.tq / 1000).toFixed(2)}s  rows=${result.rows}`);

            const record = { ttf: result.ttf, tq: result.tq, rows: result.rows, frames: result.frames, ts: result.ts || Date.now() };
            deepPush(duckdbData, keys, record);
            fs.writeFileSync(DUCKDB_JSON, JSON.stringify(duckdbData, null, 2));

            appendCSVRow(['duckdb', source, '', query, sf, i + 1, result.ttf, result.tq, result.rows, result.frames, record.ts]);

          } catch (err) {
            console.error(`     ERROR: ${err.message}`);
          }
        }
      }
    }
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  const server  = await startServer(RUNNER_DIR, config.serverPort);
  const browser = await chromium.launch({ headless: true });

  const startTime = Date.now();
  console.log(`Experiment started at ${new Date().toISOString()}`);

  try {
    const runDv = config.dvisor.enabled && !ONLY_DK;
    const runDk = config.duckdb.enabled && !ONLY_DV;

    if (runDv) await runDvisor(browser);
    if (runDk) await runDuckDB(browser);

    const elapsed = ((Date.now() - startTime) / 1000 / 60).toFixed(1);
    console.log(`\n══ All experiments done (${elapsed} min) ══`);
    console.log('Generating tables…');

    require('./generate-tables.js');

  } finally {
    await browser.close();
    server.close();
  }
}

main().catch(err => {
  console.error('\nFatal error:', err.message);
  process.exit(1);
});
