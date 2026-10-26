/* =====================================================================
   FAY LIVE — PC CENTRALE
   Programma che gira sul PC centrale in piscina. Fa tre cose:
   1) distribuisce le pagine (pc.html, report.html…) e le librerie che di solito
      arrivano da internet, così si aprono anche senza linea;
   2) risponde "nello stesso linguaggio di Supabase": pc.html non sa di parlare con
      il PC centrale invece che con il cloud, e resta UN SOLO FILE per locali e piscine;
   3) tiene database (dati/centrale.db) e foto (dati/file/) su questo PC.
   Avvio: doppio clic su avvia.bat (oppure: node server.mjs)
   ===================================================================== */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { exec } from "node:child_process";

const PORTA = Number(process.env.FAY_PORTA || 8787);
const BASE = path.dirname(fileURLToPath(import.meta.url));
const DATI = path.join(BASE, "dati");
const FILE = path.join(DATI, "file");
const PAGINE = path.join(BASE, "pagine");
const LIB = path.join(BASE, "lib");
const SITO = "https://fay-live.vercel.app";
// il cloud di Fay Live (stessi indirizzo e chiave pubblica che stanno dentro pc.html)
const CLOUD_URL = process.env.FAY_CLOUD_URL || "https://uqaddhbayyhudbmqixic.supabase.co";
const statoCloud = { online: false, ultimoContatto: null, avvisi: [] };
const CLOUD_KEY = process.env.FAY_CLOUD_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxYWRkaGJheXlodWRibXFpeGljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxODE5NDAsImV4cCI6MjEwMDc1Nzk0MH0.KNW8Wo6b3l87cZWEUncaFVgnHYS_RVWx0GwX8B1rY50";
fs.mkdirSync(FILE, { recursive: true });
fs.mkdirSync(PAGINE, { recursive: true });

/* ---------------- database ----------------
   Una tabella sola: (tabella, chiave, riga in JSON). Tutto viene anche tenuto in
   memoria per rispondere subito; ogni modifica è scritta su disco PRIMA di rispondere,
   quindi uno spegnimento improvviso non perde quello che pc.html crede salvato. */
const db = new DatabaseSync(path.join(DATI, "centrale.db"));
db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
db.exec("CREATE TABLE IF NOT EXISTS righe (tab TEXT NOT NULL, chiave TEXT NOT NULL, dati TEXT NOT NULL, PRIMARY KEY(tab, chiave))");
/* Registro per lo SPECCHIO verso il cloud:
   da_inviare  = righe cambiate qui e non ancora mandate (ver cresce a ogni modifica)
   inviati     = righe già presenti sul cloud perché mandate da qui (solo queste si cancellano lassù)
   mappa       = giornate che sul cloud hanno un altro identificativo
   file_da_inviare = anteprime e originali da caricare sul cloud
   stato       = piccole impostazioni interne */
db.exec(`CREATE TABLE IF NOT EXISTS da_inviare (tab TEXT, chiave TEXT, op TEXT, ver INTEGER, PRIMARY KEY(tab, chiave));
         CREATE TABLE IF NOT EXISTS inviati (tab TEXT, chiave TEXT, PRIMARY KEY(tab, chiave));
         CREATE TABLE IF NOT EXISTS mappa (tab TEXT, locale TEXT, cloud TEXT, PRIMARY KEY(tab, locale));
         CREATE TABLE IF NOT EXISTS file_da_inviare (bucket TEXT, percorso TEXT, ver INTEGER, PRIMARY KEY(bucket, percorso));
         CREATE TABLE IF NOT EXISTS stato (k TEXT PRIMARY KEY, v TEXT);`);
const SPECCHIATE = new Set(["sedi", "servizi", "rulli", "foto", "attivita"]);
const stSegna = db.prepare(`INSERT INTO da_inviare (tab, chiave, op, ver) VALUES (?, ?, ?, 1)
                            ON CONFLICT(tab, chiave) DO UPDATE SET op = excluded.op, ver = da_inviare.ver + 1`);
const stSegnaFile = db.prepare(`INSERT INTO file_da_inviare (bucket, percorso, ver) VALUES (?, ?, 1)
                                ON CONFLICT(bucket, percorso) DO UPDATE SET ver = file_da_inviare.ver + 1`);
const stIns = db.prepare("INSERT OR REPLACE INTO righe (tab, chiave, dati) VALUES (?, ?, ?)");
const stDel = db.prepare("DELETE FROM righe WHERE tab = ? AND chiave = ?");

const CHIAVI = { impostazioni: ["chiave"], tavoli: ["codice"], vetrina_foto: ["vetrina_id", "foto_id"] };
const UNICI = { sedi: [["codice"]], servizi: [["sede_id", "data_servizio"]], rulli: [["servizio_id", "lettera"]], foto: [["rullo_id", "codice"]], vetrine: [["codice"]] };
const ora = () => new Date().toISOString();
const PREDEFINITI = {
  sedi:     () => ({ creata_il: ora() }),
  servizi:  () => ({ creato_il: ora() }),
  rulli:    () => ({ ultimo_num: 0, creato_il: ora(), omaggi: 0, scarti: 0, file: 0, file_venduti: 0 }),
  foto:     () => ({ stampe: 0, esportata: false, creata_il: ora(), richiesta_originale: false, da_stampare: false,
                     omaggi: 0, scarti: 0, copie: 1, conserva: false }),
  attivita: () => ({ creato_il: ora() }),
};
// cancellazioni a cascata, come sul cloud
const FIGLI = { sedi: [["servizi", "sede_id"]], servizi: [["rulli", "servizio_id"]], rulli: [["foto", "rullo_id"]],
                vetrine: [["vetrina_foto", "vetrina_id"]] };
// relazioni per le select annidate (es. rulli!inner(servizi!inner(...)))
const FK = { rulli: "rullo_id", servizi: "servizio_id", sedi: "sede_id", vetrine: "vetrina_id", foto: "foto_id" };

const tabelle = new Map();
function tab(nome) {
  if (!tabelle.has(nome)) tabelle.set(nome, new Map());
  return tabelle.get(nome);
}
for (const r of db.prepare("SELECT tab, chiave, dati FROM righe").all()) tab(r.tab).set(r.chiave, JSON.parse(r.dati));
const pk = nome => CHIAVI[nome] || ["id"];
const chiaveDi = (nome, riga) => pk(nome).map(c => String(riga[c])).join("|");
function salva(nome, riga, daCloud) {
  stIns.run(nome, chiaveDi(nome, riga), JSON.stringify(riga)); tab(nome).set(chiaveDi(nome, riga), riga);
  if (!daCloud && SPECCHIATE.has(nome)) stSegna.run(nome, chiaveDi(nome, riga), "up");
}
function elimina(nome, riga, daCloud) {
  for (const [figlio, col] of (FIGLI[nome] || []))
    for (const f of [...tab(figlio).values()]) if (String(f[col]) === String(riga.id)) elimina(figlio, f, daCloud);
  stDel.run(nome, chiaveDi(nome, riga)); tab(nome).delete(chiaveDi(nome, riga));
  if (!daCloud && SPECCHIATE.has(nome)) stSegna.run(nome, chiaveDi(nome, riga), "del");
}
function inTransazione(fn) {
  db.exec("BEGIN");
  try { const r = fn(); db.exec("COMMIT"); return r; }
  catch (e) { try { db.exec("ROLLBACK"); } catch (_) {} ricarica(); throw e; }
}
// dopo un errore a metà la memoria potrebbe essere avanti al disco: si riallinea dal disco
function ricarica() {
  tabelle.clear();
  for (const r of db.prepare("SELECT tab, chiave, dati FROM righe").all()) tab(r.tab).set(r.chiave, JSON.parse(r.dati));
}

/* Gli indirizzi delle foto scritti nelle righe diventano RELATIVI ("/storage/v1/…"):
   il PC centrale li vede come localhost, le postazioni come 192.168.x.x. Con l'indirizzo
   completo una postazione avrebbe cercato le anteprime su "localhost", cioè su sé stessa. */
const reOrigine = new RegExp("^https?://[^/]+:" + PORTA + "(?=/storage/v1/)");
function relativizza(v) {
  if (typeof v === "string") return v.replace(reOrigine, "");
  return v;
}

/* ---------------- select e filtri (sottoinsieme di PostgREST) ---------------- */
function spezza(s) {           // virgole al primo livello, rispettando le parentesi
  const out = []; let liv = 0, cur = "";
  for (const ch of s) {
    if (ch === "(") liv++;
    if (ch === ")") liv--;
    if (ch === "," && liv === 0) { out.push(cur); cur = ""; } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map(x => x.trim()).filter(Boolean);
}
function leggiSelect(s) {
  if (!s) return [{ tipo: "tutto" }];
  return spezza(s).map(it => {
    const m = /^(?:(\w+):)?(\w+)((?:!\w+)*)\((.*)\)$/s.exec(it);
    if (m) return { tipo: "rel", alias: m[1] || m[2], nome: m[2], inner: m[3].includes("!inner"), figli: leggiSelect(m[4]) };
    if (it === "*") return { tipo: "tutto" };
    const c = /^(?:(\w+):)?(\w+)(?:::\w+)?$/.exec(it);
    if (c) return { tipo: "col", alias: c[1] || c[2], nome: c[2] };
    throw errore(400, "PGRST100", "select non supportata: " + it);
  });
}
// riga collegata: molti-a-uno (foto.rullo_id -> rulli) oppure uno-a-molti (rulli -> foto[])
function collegati(nomeTab, riga, rel) {
  const fk = FK[rel];
  if (fk && riga[fk] !== undefined) return [...tab(rel).values()].find(r => String(r.id) === String(riga[fk])) || null;
  const fkMio = FK[nomeTab];
  return [...tab(rel).values()].filter(r => fkMio && String(r[fkMio]) === String(riga.id));
}
function proietta(nomeTab, riga, voci) {
  const out = {};
  for (const v of voci) {
    if (v.tipo === "tutto") Object.assign(out, riga);
    else if (v.tipo === "col") out[v.alias] = riga[v.nome] === undefined ? null : riga[v.nome];
    else {
      const c = collegati(nomeTab, riga, v.nome);
      out[v.alias] = Array.isArray(c) ? c.map(x => proietta(v.nome, x, v.figli)) : (c ? proietta(v.nome, c, v.figli) : null);
    }
  }
  return out;
}
function innerOk(nomeTab, riga, voci) {
  for (const v of voci) if (v.tipo === "rel" && v.inner) {
    const c = collegati(nomeTab, riga, v.nome);
    if (!c || (Array.isArray(c) && !c.length)) return false;
    const sotto = Array.isArray(c) ? c : [c];
    if (!sotto.some(x => innerOk(v.nome, x, v.figli))) return false;
  }
  return true;
}
// valore di una colonna, anche annidata: "rulli.servizi.sede_id"
function valoreDi(nomeTab, riga, percorso) {
  const pezzi = percorso.split(".");
  let t = nomeTab, r = riga;
  for (let i = 0; i < pezzi.length - 1; i++) {
    const c = collegati(t, r, pezzi[i]);
    r = Array.isArray(c) ? c[0] : c; t = pezzi[i];
    if (!r) return undefined;
  }
  return r[pezzi[pezzi.length - 1]];
}
function uguale(a, b) {
  if (a === null || a === undefined) return false;
  if (typeof a === "boolean") return String(a) === b;
  if (typeof a === "number") return b !== "" && Number(b) === a;
  return String(a) === b;
}
function confronta(a, b) {
  if (typeof a === "number" && b !== "" && !isNaN(Number(b))) return a - Number(b);
  const x = String(a), y = String(b);
  return x < y ? -1 : x > y ? 1 : 0;
}
function listaIn(s) {
  const m = /^\((.*)\)$/s.exec(s); if (!m) return [];
  const out = []; let cur = "", q = false;
  for (const ch of m[1]) {
    if (ch === '"') { q = !q; continue; }
    if (ch === "," && !q) { out.push(cur); cur = ""; } else cur += ch;
  }
  out.push(cur);
  return out;
}
function provaFiltro(a, espr) {
  let neg = false;
  if (espr.startsWith("not.")) { neg = true; espr = espr.slice(4); }
  const i = espr.indexOf("."); const op = espr.slice(0, i), val = espr.slice(i + 1);
  let ok;
  switch (op) {
    case "eq": ok = uguale(a, val); break;
    case "neq": ok = a !== null && a !== undefined && !uguale(a, val); break;
    case "gt": ok = a != null && confronta(a, val) > 0; break;
    case "gte": ok = a != null && confronta(a, val) >= 0; break;
    case "lt": ok = a != null && confronta(a, val) < 0; break;
    case "lte": ok = a != null && confronta(a, val) <= 0; break;
    case "in": ok = listaIn(val).some(v => uguale(a, v)); break;
    case "is": ok = val === "null" ? a == null : val === "true" ? a === true : val === "false" ? a === false : false; break;
    case "like": case "ilike": {
      const re = new RegExp("^" + val.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/[*%]/g, ".*") + "$", op === "ilike" ? "i" : "");
      ok = a != null && re.test(String(a)); break;
    }
    default: throw errore(400, "PGRST100", "filtro non supportato: " + op);
  }
  return neg ? !ok : ok;
}
const RISERVATI = new Set(["select", "order", "limit", "offset", "on_conflict", "columns"]);
function righeFiltrate(nomeTab, q, voci) {
  const filtri = [];
  for (const [k, v] of q) {
    if (RISERVATI.has(k)) continue;
    if (k === "or" || k === "and") throw errore(400, "PGRST100", "filtro or/and non supportato");
    filtri.push([k, v]);
  }
  return [...tab(nomeTab).values()].filter(r =>
    filtri.every(([k, v]) => provaFiltro(valoreDi(nomeTab, r, k), v)) && (!voci || innerOk(nomeTab, r, voci)));
}
function ordina(righe, ordine) {
  if (!ordine) return righe;
  const crit = ordine.split(",").map(s => { const p = s.split("."); return { col: p[0], desc: p.includes("desc"), nullsFirst: p.includes("nullsfirst") }; });
  return righe.sort((x, y) => {
    for (const c of crit) {
      const a = x[c.col], b = y[c.col];
      if (a == null || b == null) {
        if (a == null && b == null) continue;
        const n = (a == null ? -1 : 1) * (c.nullsFirst ? 1 : -1);
        return c.desc ? -n : n;
      }
      const d = typeof a === "number" && typeof b === "number" ? a - b : String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0;
      if (d) return c.desc ? -d : d;
    }
    return 0;
  });
}

/* ---------------- funzioni del database (rpc) ---------------- */
function rullo(id) { return [...tab("rulli").values()].find(r => String(r.id) === String(id)) || null; }
const FUNZIONI = {
  prossimo_codice_da({ p_rullo_id, p_quanti, p_minimo }) {
    const r = rullo(p_rullo_id); if (!r) return null;
    r.ultimo_num = Math.max(r.ultimo_num || 0, Number(p_minimo) || 0) + (Number(p_quanti) || 0);
    salva("rulli", r); return r.ultimo_num;
  },
  prossimo_codice_blocco({ p_rullo_id, p_quanti }) {
    const r = rullo(p_rullo_id); if (!r) return null;
    r.ultimo_num = (r.ultimo_num || 0) + (Number(p_quanti) || 0); salva("rulli", r); return r.ultimo_num;
  },
  prossimo_codice({ p_rullo_id }) {
    const r = rullo(p_rullo_id); if (!r) return null;
    r.ultimo_num = (r.ultimo_num || 0) + 1; salva("rulli", r); return r.ultimo_num;
  },
  segna_stat({ p_rullo, p_campo, p_delta }) {
    if (!["omaggi", "scarti", "file_venduti"].includes(p_campo)) throw errore(400, "P0001", "campo non ammesso");
    const r = rullo(p_rullo); if (!r) return null;
    r[p_campo] = Math.max(0, (r[p_campo] || 0) + (Number(p_delta) || 0)); salva("rulli", r); return null;
  },
};

/* ---------------- risposte ---------------- */
function errore(stato, code, message) { const e = new Error(message); e.stato = stato; e.code = code; return e; }
function json(res, stato, corpo, extra) {
  const t = corpo === undefined ? "" : JSON.stringify(corpo);
  res.writeHead(stato, Object.assign({ "Content-Type": "application/json; charset=utf-8" }, extra || {}));
  res.end(t);
}
function leggiCorpo(req) {
  return new Promise((ok, ko) => { const parti = []; req.on("data", c => parti.push(c)); req.on("end", () => ok(Buffer.concat(parti))); req.on("error", ko); });
}
function prefer(req) {
  const p = {}; String(req.headers["prefer"] || "").split(",").forEach(x => { const [k, v] = x.trim().split("="); if (k) p[k] = v; });
  return p;
}

async function rest(req, res, url) {
  const nome = decodeURIComponent(url.pathname.slice("/rest/v1/".length));
  const q = url.searchParams, pref = prefer(req);
  const oggetto = String(req.headers["accept"] || "").includes("vnd.pgrst.object");
  const metodo = req.method;

  if (nome.startsWith("rpc/")) {
    const fn = FUNZIONI[nome.slice(4)];
    if (!fn) throw errore(404, "PGRST202", "funzione sconosciuta: " + nome.slice(4));
    const corpo = await leggiCorpo(req);
    const args = corpo.length ? JSON.parse(corpo.toString("utf8")) : Object.fromEntries(q);
    const r = inTransazione(() => fn(args));
    if (r === null || r === undefined) { res.writeHead(204); return res.end(); }
    return json(res, 200, r);
  }
  if (!/^\w+$/.test(nome)) throw errore(404, "PGRST205", "tabella sconosciuta");
  const voci = leggiSelect(q.get("select"));
  const risposta = (righe, stato, totale) => {
    let out = righe.map(r => proietta(nome, r, voci));
    const testa = {};
    if (pref.count) testa["Content-Range"] = (out.length ? `0-${out.length - 1}` : "*") + "/" + (totale ?? out.length);
    if (metodo === "HEAD") { res.writeHead(200, testa); return res.end(); }
    if (oggetto) {
      if (out.length !== 1) return json(res, 406, { code: "PGRST116", details: `Results contain ${out.length} rows`, hint: null, message: "JSON object requested, multiple (or no) rows returned" });
      return json(res, stato, out[0], testa);
    }
    if ((metodo === "POST" || metodo === "PATCH" || metodo === "DELETE") && pref.return !== "representation") { res.writeHead(stato === 200 ? 204 : stato, testa); return res.end(); }
    return json(res, stato, out, testa);
  };

  if (metodo === "GET" || metodo === "HEAD") {
    let righe = ordina(righeFiltrate(nome, q, voci), q.get("order"));
    const totale = righe.length;
    const da = Number(q.get("offset") || 0), lim = q.has("limit") ? Number(q.get("limit")) : Infinity;
    righe = righe.slice(da, da + lim);
    return risposta(righe, 200, totale);
  }

  if (metodo === "POST") {
    const corpo = JSON.parse((await leggiCorpo(req)).toString("utf8") || "null");
    const lista = Array.isArray(corpo) ? corpo : [corpo];
    const unisci = pref.resolution === "merge-duplicates", ignora = pref.resolution === "ignore-duplicates";
    const bersaglio = q.get("on_conflict") ? q.get("on_conflict").split(",").map(s => s.trim()) : pk(nome);
    const fatte = inTransazione(() => {
      const out = [];
      for (const dato of lista) {
        const nuova = {};
        for (const [k, v] of Object.entries(dato || {})) nuova[k] = relativizza(v);
        const esistente = (unisci || ignora) && bersaglio.every(c => nuova[c] !== undefined)
          ? [...tab(nome).values()].find(r => bersaglio.every(c => String(r[c]) === String(nuova[c]))) : null;
        if (esistente) {
          if (ignora) continue;
          Object.assign(esistente, nuova); salva(nome, esistente); out.push(esistente); continue;
        }
        const riga = Object.assign({}, (PREDEFINITI[nome] || (() => ({})))(), nuova);
        /* REGOLA DELLE PISCINE: una giornata nata senza linea resta "solo numeri" per
           sempre (al cloud salgono solo i conteggi per il report); una nata con la linea
           viene specchiata tutta, anche se la linea poi cade (si rimette in pari dopo). */
        if (nome === "servizi" && riga.solo_locale === undefined) riga.solo_locale = !statoCloud.online;
        if (pk(nome)[0] === "id" && (riga.id === undefined || riga.id === null)) riga.id = crypto.randomUUID();
        if (tab(nome).has(chiaveDi(nome, riga)))
          throw errore(409, "23505", `duplicate key value violates unique constraint "${nome}_pkey"`);
        for (const u of (UNICI[nome] || []))
          if (u.every(c => riga[c] != null) && [...tab(nome).values()].some(r => u.every(c => String(r[c]) === String(riga[c]))))
            throw errore(409, "23505", `duplicate key value violates unique constraint "${nome}_${u.join("_")}_key"`);
        salva(nome, riga); out.push(riga);
      }
      return out;
    });
    return risposta(fatte, 201);
  }

  if (metodo === "PATCH") {
    const corpo = JSON.parse((await leggiCorpo(req)).toString("utf8") || "{}");
    const fatte = inTransazione(() => {
      const righe = righeFiltrate(nome, q, null);
      for (const r of righe) {
        const vecchiaChiave = chiaveDi(nome, r);
        for (const [k, v] of Object.entries(corpo)) r[k] = relativizza(v);
        if (chiaveDi(nome, r) !== vecchiaChiave) { stDel.run(nome, vecchiaChiave); tab(nome).delete(vecchiaChiave); }
        salva(nome, r);
      }
      return righe;
    });
    return risposta(fatte, 200);
  }

  if (metodo === "DELETE") {
    const fatte = inTransazione(() => { const righe = righeFiltrate(nome, q, null); righe.forEach(r => elimina(nome, r)); return righe; });
    return risposta(fatte, 200);
  }
  throw errore(405, "PGRST117", "metodo non supportato");
}

/* ---------------- storage (anteprime, originali, vetrine…) ---------------- */
function percorsoFile(bucket, p) {
  const pulito = path.normalize(decodeURIComponent(p)).replace(/^([/\\])+/, "");
  if (!/^[\w.-]+$/.test(bucket) || pulito.split(/[/\\]/).includes("..")) throw errore(400, "invalid", "percorso non valido");
  return path.join(FILE, bucket, pulito);
}
const TIPI = { ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp", ".gif": "image/gif",
               ".json": "application/json", ".txt": "text/plain", ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
               ".css": "text/css", ".svg": "image/svg+xml", ".pdf": "application/pdf" };
function serviFile(res, f, extra) {
  fs.stat(f, (err, st) => {
    if (err || !st.isFile()) return json(res, 400, { statusCode: "404", error: "not_found", message: "Object not found" });
    res.writeHead(200, Object.assign({ "Content-Type": TIPI[path.extname(f).toLowerCase()] || "application/octet-stream",
      "Content-Length": st.size, "Cache-Control": "no-cache" }, extra || {}));
    fs.createReadStream(f).pipe(res);
  });
}
async function storage(req, res, url) {
  const p = url.pathname.slice("/storage/v1/".length);
  let m;
  if ((m = /^object\/(?:public|authenticated)\/([^/]+)\/(.+)$/.exec(p)) && (req.method === "GET" || req.method === "HEAD"))
    return serviFile(res, percorsoFile(m[1], m[2]));
  if ((m = /^object\/sign\/([^/]+)\/(.+)$/.exec(p))) {
    if (req.method === "POST") { await leggiCorpo(req); return json(res, 200, { signedURL: `/object/sign/${m[1]}/${m[2]}?token=centrale` }); }
    return serviFile(res, percorsoFile(m[1], m[2]));
  }
  if ((m = /^object\/list\/([^/]+)$/.exec(p)) && req.method === "POST") {
    const corpo = JSON.parse((await leggiCorpo(req)).toString("utf8") || "{}");
    const dir = percorsoFile(m[1], corpo.prefix || "");
    let voci = [];
    try { voci = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) {}
    voci.sort((a, b) => a.name < b.name ? -1 : 1);
    const da = Number(corpo.offset || 0), lim = Number(corpo.limit || 100);
    const out = voci.slice(da, da + lim).map(v => {
      if (v.isDirectory()) return { name: v.name, id: null, updated_at: null, created_at: null, last_accessed_at: null, metadata: null };
      const st = fs.statSync(path.join(dir, v.name));
      return { name: v.name, id: crypto.createHash("md5").update(path.join(dir, v.name)).digest("hex"), updated_at: st.mtime.toISOString(),
               created_at: st.birthtime.toISOString(), last_accessed_at: st.atime.toISOString(),
               metadata: { size: st.size, mimetype: TIPI[path.extname(v.name).toLowerCase()] || "application/octet-stream" } };
    });
    return json(res, 200, out);
  }
  if ((m = /^object\/([^/]+)$/.exec(p)) && req.method === "DELETE") {
    const corpo = JSON.parse((await leggiCorpo(req)).toString("utf8") || "{}");
    const tolti = [];
    for (const pr of (corpo.prefixes || [])) {
      try { fs.unlinkSync(percorsoFile(m[1], pr)); tolti.push({ name: pr, bucket_id: m[1] }); } catch (_) {}
    }
    return json(res, 200, tolti);
  }
  if ((m = /^object\/([^/]+)\/(.+)$/.exec(p))) {
    const f = percorsoFile(m[1], m[2]);
    if (req.method === "GET" || req.method === "HEAD") return serviFile(res, f);
    if (req.method === "POST" || req.method === "PUT") {
      const corpo = await leggiCorpo(req);
      const ct = String(req.headers["content-type"] || "");
      let dati = corpo;
      if (ct.startsWith("multipart/form-data")) {
        const fd = await new Request("http://centrale/", { method: "POST", headers: { "content-type": ct }, body: corpo }).formData();
        let trovato = null;
        for (const [, v] of fd) if (typeof v === "object" && v && typeof v.arrayBuffer === "function") { trovato = v; break; }
        if (!trovato) throw errore(400, "invalid", "nessun file nel caricamento");
        dati = Buffer.from(await trovato.arrayBuffer());
      }
      const sovrascrivi = String(req.headers["x-upsert"] || "") === "true" || req.method === "PUT";
      if (fs.existsSync(f) && !sovrascrivi) return json(res, 400, { statusCode: "409", error: "Duplicate", message: "The resource already exists" });
      fs.mkdirSync(path.dirname(f), { recursive: true });
      const tmp = f + ".tmp-" + process.pid;
      fs.writeFileSync(tmp, dati); fs.renameSync(tmp, f);       // mai un file mezzo scritto
      if (m[1] === "originali") collegaLeggibile(decodeURIComponent(m[2]), true);   // copia leggibile in Archivio
      if ((m[1] === "anteprime" || m[1] === "originali") && /^[0-9a-f-]{36}\//.test(decodeURIComponent(m[2])))
        stSegnaFile.run(m[1], decodeURIComponent(m[2]));
      return json(res, 200, { Key: `${m[1]}/${m[2]}`, Id: crypto.randomUUID() });
    }
  }
  throw errore(404, "not_found", "percorso storage sconosciuto");
}

/* ---------------- ARCHIVIO LEGGIBILE (8 ott) ----------------
   Dentro dati\file\originali le cartelle e i file hanno gli identificativi di giornata e
   rullo (servono: i codici si ripetono ogni giorno e senza identificativi un rullo nuovo
   finiva sopra le foto di un'altra sera). Per le persone c'è in più la cartella
       FayCentrale\Archivio\<Sede>\<data>\<lettera>\L-001.jpg
   con ogni originale sotto il suo codice vero. Non occupa spazio doppio: è un
   "collegamento fisico" di Windows, cioè lo STESSO file con un secondo nome (se il disco
   non li supporta si fa una copia). Si crea a ogni import e, ogni 10 minuti e all'avvio,
   si sistemano quelli mancanti (anche le foto importate prima di questa versione).
   Cancellare qualcosa in Archivio non tocca i dati del programma. Svuotando una giornata
   o cancellando una sede da Fay Live le foto in Archivio RESTANO, come in C:\FayLive:
   gli originali sul PC non si cancellano mai da soli. */
const ARCHIVIO = process.env.FAY_ARCHIVIO || path.join(BASE, "Archivio");
const nomeCartella = s => String(s || "").replace(/[<>:"/\\|?*\x00-\x1f]/g, " ").replace(/\s+/g, " ").trim().replace(/[. ]+$/, "");
function percorsoLeggibile(percorso) {
  const parti = String(percorso).split("/");
  if (parti.length !== 2) return null;
  const [idGiornata, nomeFile] = parti;
  const g = tab("servizi").get(idGiornata);
  if (!g || !g.data_servizio) return null;
  const sede = tab("sedi").get(String(g.sede_id));
  const nomeSede = sede && nomeCartella(sede.nome);
  if (!nomeSede) return null;                       // sede non ancora nota: ci pensa il giro successivo
  const m = /^(?:([0-9a-f]{8})-)?(.+)\.(jpe?g|png|webp|tiff?)$/i.exec(nomeFile);
  if (!m) return null;
  const codice = nomeCartella(m[2]);
  let lettera = null;
  if (m[1]) {
    const r = [...tab("rulli").values()].find(x => String(x.servizio_id) === idGiornata &&
                                                  String(x.id).replace(/-/g, "").startsWith(m[1]));
    if (r) lettera = r.lettera;
  }
  if (!lettera) lettera = codice.split("-")[0];
  lettera = nomeCartella(lettera);
  if (!codice || !lettera) return null;
  return path.join(ARCHIVIO, nomeSede, nomeCartella(g.data_servizio), lettera, codice + "." + m[3].toLowerCase());
}
// crea (o rifà, se l'originale è stato reimportato) il nome leggibile; true = fatto adesso
function collegaLeggibile(percorso, forza) {
  try {
    const dest = percorsoLeggibile(percorso);
    if (!dest) return false;
    const src = percorsoFile("originali", percorso);
    const st = fs.statSync(src);
    if (!forza) {
      try {
        const sd = fs.statSync(dest);
        if (sd.size === st.size && sd.mtimeMs >= st.mtimeMs) return false;     // già a posto
      } catch (_) {}
    }
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = dest + ".tmp-" + process.pid;
    try { fs.unlinkSync(tmp); } catch (_) {}
    try { fs.linkSync(src, tmp); } catch (_) { fs.copyFileSync(src, tmp); }
    fs.renameSync(tmp, dest);
    return true;
  } catch (e) {
    console.log("  ⚠ archivio leggibile:", percorso, e.message);
    return false;
  }
}
function riordinaArchivio() {
  const base = path.join(FILE, "originali");
  let giornate = [], nuove = 0;
  try { giornate = fs.readdirSync(base, { withFileTypes: true }).filter(d => d.isDirectory()); } catch (_) { return; }
  for (const d of giornate) {
    let nomi = [];
    try { nomi = fs.readdirSync(path.join(base, d.name)); } catch (_) { continue; }
    for (const n of nomi) if (!n.includes(".tmp-") && collegaLeggibile(d.name + "/" + n)) nuove++;
  }
  if (nuove) console.log(`  ✓ Archivio leggibile: ${nuove} ${nuove === 1 ? "foto sistemata" : "foto sistemate"} in ${ARCHIVIO}`);
}

/* ---------------- pagine ----------------
   Le pagine sono le stesse del sito: al volo si cambiano solo gli indirizzi delle
   librerie (copie locali) e quello del "cloud" (questo PC). */
function adattaPagina(html) {
  return html
    .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2[^"']*/g, "/lib/supabase.js")
    .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/qrcode-generator@[^"']*/g, "/lib/qrcode.js")
    .replace(/const SB_URL\s*=\s*"[^"]*";/, "const SB_URL = location.origin;")
    .replace(/<head>/i, "<head><script>window.FAY_CENTRALE = true;</script>");
}
async function aggiornaPagine() {
  for (const nome of ["pc.html", "report.html"]) {
    try {
      const r = await fetch(`${SITO}/${nome}?nc=${Date.now()}`, { signal: AbortSignal.timeout(8000) });
      const t = await r.text();
      if (r.ok && t.includes("Fay Live")) { fs.writeFileSync(path.join(PAGINE, nome), t); console.log(`  ✓ ${nome} aggiornata dal sito`); }
    } catch (_) {
      console.log(`  · ${nome}: sito non raggiungibile, uso la copia salvata`);
    }
  }
}

/* ---------------- dal cloud al PC centrale ----------------
   All'avvio, se c'è linea, si copiano dal cloud TUTTE le sedi con lo STESSO
   identificativo, più le loro impostazioni (mascherine, logo, impostazioni salvate).
   Le giornate e le foto dei locali NON si copiano: pesano e in piscina non servono.
   Stesso identificativo = stessa sede da tutte e due le parti: quando i dati della
   piscina risaliranno sul cloud, si agganciano alla sede giusta senza confrontare nomi.
   Una sede creata qui offline con lo stesso nome di una del cloud viene UNITA a quella
   del cloud (le sue giornate passano alla sede del cloud): mai due sedi con lo stesso nome. */
const normNome = x => String(x || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
async function chiediCloud(percorso) {
  const r = await fetch(CLOUD_URL + percorso, { headers: { apikey: CLOUD_KEY, Authorization: "Bearer " + CLOUD_KEY },
                                                 signal: AbortSignal.timeout(10000) });
  return r;
}
async function scaricaDalCloud(silenzioso) {
  let sedi;
  try {
    const r = await chiediCloud("/rest/v1/sedi?select=*");
    if (!r.ok) throw new Error("risposta " + r.status);
    sedi = await r.json();
  } catch (e) {
    if (!silenzioso) console.log("  · cloud non raggiungibile: sedi non aggiornate (" + e.message + ")");
    statoCloud.online = false;
    return;
  }
  if (!Array.isArray(sedi)) return;
  statoCloud.online = true;
  statoCloud.ultimeSedi = Date.now();
  let nuove = 0, unite = 0, tolte = 0;
  const sediNuove = [];
  inTransazione(() => {
    for (const sc of sedi) {
      const locale = tab("sedi").get(String(sc.id));
      if (locale) { Object.assign(locale, sc); salva("sedi", locale, true); continue; }
      // stessa sede creata qui con un altro identificativo: si unisce a quella del cloud
      const doppia = [...tab("sedi").values()].find(x => normNome(x.nome) === normNome(sc.nome));
      salva("sedi", Object.assign({}, sc), true); nuove++; sediNuove.push(sc);
      db.prepare("INSERT OR IGNORE INTO inviati (tab, chiave) VALUES ('sedi', ?)").run(String(sc.id));
      if (doppia) {
        for (const g of [...tab("servizi").values()].filter(g => String(g.sede_id) === String(doppia.id))) {
          const stessaData = [...tab("servizi").values()].find(x => String(x.sede_id) === String(sc.id) && x.data_servizio === g.data_servizio);
          if (stessaData) {
            // la stessa data esiste già anche sotto la sede del cloud: i rulli passano lì (lettere diverse) o restano separati
            for (const r of [...tab("rulli").values()].filter(r => String(r.servizio_id) === String(g.id))) {
              const conflitto = [...tab("rulli").values()].some(x => String(x.servizio_id) === String(stessaData.id) && x.lettera === r.lettera);
              if (!conflitto) { r.servizio_id = stessaData.id; salva("rulli", r); }
              else console.log(`  ⚠ ${sc.nome} ${g.data_servizio}: rullo ${r.lettera} presente due volte, lasciato separato`);
            }
            if (![...tab("rulli").values()].some(r => String(r.servizio_id) === String(g.id))) elimina("servizi", g);
          } else { g.sede_id = sc.id; salva("servizi", g); }
        }
        if (![...tab("servizi").values()].some(g => String(g.sede_id) === String(doppia.id))) elimina("sedi", doppia);
        unite++;
      }
    }
  });

  /* SEDI CANCELLATE SUL CLOUD ("Cancella sede" dal sito): si tolgono anche qui, con le
     loro giornate e i loro file. Si tocca solo una sede che il cloud conosceva (mandata da
     qui o arrivata da lì). Due protezioni:
     · se la sede ha qui dati MAI arrivati al cloud (giornata offline non ancora inviata),
       non si cancella niente: la sede viene rimandata su e lo si segnala;
     · se sparisce di colpo più di metà delle sedi (risposta strana del cloud) non si
       cancella niente. */
  const idsCloud = new Set(sedi.map(x => String(x.id)));
  /* "conosciuta dal cloud" = segnata come inviata, OPPURE senza un invio in sospeso.
     Una sede creata qui e mai arrivata lassù ha sempre il suo invio in sospeso, quindi non
     si tocca. Prima contava solo il segno "inviata", che mancava alle sedi arrivate col
     primissimo avvio: cancellate dal sito, qui restavano. */
  const qSospesa = db.prepare("SELECT 1 FROM da_inviare WHERE tab = 'sedi' AND chiave = ? AND op = 'up'");
  const sparite = [...tab("sedi").values()].filter(x => !idsCloud.has(String(x.id)) &&
    (inviato("sedi", x.id) || !qSospesa.get(String(x.id))));
  if (sparite.length && (sedi.length === 0 || sparite.length > Math.max(2, tab("sedi").size / 2))) {
    console.log(`  ⚠ il cloud non elenca ${sparite.length} sedi: per prudenza non cancello niente`);
  } else {
    for (const sd of sparite) {
      const giornate = [...tab("servizi").values()].filter(g => String(g.sede_id) === String(sd.id)).map(g => String(g.id));
      const gSet = new Set(giornate);
      const inSospeso = db.prepare("SELECT tab, chiave FROM da_inviare WHERE op = 'up'").all().some(v => {
        const riga = tab(v.tab).get(v.chiave); if (!riga) return false;
        const g = giornataDi(v.tab, riga); return g && gSet.has(String(g.id));
      }) || db.prepare("SELECT percorso FROM file_da_inviare").all().some(f => gSet.has(f.percorso.split("/")[0]));
      if (inSospeso) {
        qTogliInviato.run("sedi", String(sd.id)); stSegna.run("sedi", String(sd.id), "up");
        console.log(`  ⚠ La sede "${sd.nome}" è stata cancellata sul cloud ma qui ha dati non ancora inviati: la rimando su, non perdo niente.`);
        continue;
      }
      inTransazione(() => { elimina("sedi", sd, true); qTogliInviato.run("sedi", String(sd.id)); });
      for (const g of giornate) for (const b of ["anteprime", "originali"]) {
        try { fs.rmSync(path.join(FILE, b, g), { recursive: true, force: true }); } catch (_) {}
      }
      tolte++;
      console.log(`  − sede "${sd.nome}" cancellata sul cloud: tolta anche qui`);
    }
  }
  if (silenzioso) {
    if (nuove || unite) console.log(`  ✓ sedi dal cloud: ${nuove} nuove` + (unite ? ` · ${unite} unite` : ""));
  }
  // impostazioni generali (codice di accesso dei tablet, filigrana vetrine…)
  try {
    const r = await chiediCloud("/rest/v1/impostazioni?select=*");
    if (r.ok) { const righe = await r.json(); inTransazione(() => righe.forEach(x => salva("impostazioni", x, true))); }
  } catch (_) {}
  // impostazioni di ogni sede: mascherine, logo, impostazioni salvate (se ci sono)
  let file = 0;
  const daCopiare = silenzioso ? [] : ["mascherine/nosede-maskH.png", "mascherine/nosede-maskV.png"];
  for (const sc of (silenzioso ? sediNuove : sedi)) daCopiare.push(`mascherine/${sc.id}-maskH.png`, `mascherine/${sc.id}-maskV.png`, `loghi/${sc.id}.png`, `impostazioni/${sc.id}.json`);
  {
    for (const rel of daCopiare) {
      try {
        const r = await chiediCloud(`/storage/v1/object/public/anteprime/${rel}`);
        if (!r.ok) continue;
        const dati = Buffer.from(await r.arrayBuffer());
        const f = percorsoFile("anteprime", rel);
        fs.mkdirSync(path.dirname(f), { recursive: true });
        fs.writeFileSync(f + ".tmp", dati); fs.renameSync(f + ".tmp", f); file++;
      } catch (_) {}
    }
  }
  if (!silenzioso) console.log(`  ✓ sedi dal cloud: ${sedi.length}` + (nuove ? ` (${nuove} nuove)` : "") + (unite ? ` · ${unite} unite a quelle del cloud` : "") + (tolte ? ` · ${tolte} tolte` : "") + ` · ${file} file di impostazioni`);
}

/* ---------------- dal PC centrale al cloud: lo SPECCHIO ----------------
   Ogni 20 secondi, se c'è linea, manda al cloud quello che è cambiato qui.
   · giornata nata CON la linea  → tutto: righe, anteprime e originali (tablet, sito e
     report la vedono come una giornata normale);
   · giornata nata SENZA linea   → solo i numeri: righe senza anteprime né originali,
     quanto basta al report (foto, stampe, omaggi, scarti, file). Le foto restano qui.
   Regole contro le sovrapposizioni:
   · la sede ha lo stesso identificativo qui e sul cloud (copiata all'avvio);
   · se sul cloud esiste già la giornata di quella sede e quella data, ci si aggancia a
     quella (mai una seconda giornata);
   · se in quella giornata il cloud ha già un rullo con la stessa lettera che NON viene da
     qui, quel rullo NON si manda: due rulli A di origine diversa non si mescolano mai.
     Resta segnalato nella finestra nera e in /stato. */
const COLONNE = {
  sedi: ["id", "nome", "codice", "creata_il"],
  servizi: ["id", "sede_id", "data_servizio", "nome", "logo_url", "scritta", "riga_prezzi", "creato_il", "solo_locale"],
  rulli: ["id", "servizio_id", "lettera", "descrizione", "ultimo_num", "creato_il", "omaggi", "scarti", "file", "file_venduti"],
  foto: ["id", "rullo_id", "codice", "scattata_il", "anteprima_url", "originale_url", "stampe", "esportata", "creata_il",
         "richiesta_originale", "da_stampare", "gruppo", "mini_url", "omaggi", "scarti", "copie", "ritaglio",
         "file_origine", "consegna", "consegna_dove", "conserva", "salvata_su"],
  attivita: ["id", "servizio_id", "rullo_lettera", "codici", "azione", "quante", "creato_il", "postazione", "esito", "dettaglio"],
};
const ORDINE = ["sedi", "servizi", "rulli", "foto", "attivita"];
const qInviato = db.prepare("SELECT 1 FROM inviati WHERE tab = ? AND chiave = ?");
const qSegnaInviato = db.prepare("INSERT OR IGNORE INTO inviati (tab, chiave) VALUES (?, ?)");
const qTogliInviato = db.prepare("DELETE FROM inviati WHERE tab = ? AND chiave = ?");
const qMappa = db.prepare("SELECT cloud FROM mappa WHERE tab = ? AND locale = ?");
const qSetMappa = db.prepare("INSERT OR REPLACE INTO mappa (tab, locale, cloud) VALUES (?, ?, ?)");
const qFatto = db.prepare("DELETE FROM da_inviare WHERE tab = ? AND chiave = ? AND ver = ?");
const inviato = (t, k) => !!qInviato.get(t, String(k));
const giornataCloud = idLocale => { const m = qMappa.get("servizi", String(idLocale)); return m ? m.cloud : String(idLocale); };
const conflittiRulli = new Set();         // rulli che NON si mandano (lettera già usata sul cloud da altri)

async function cloudJson(metodo, percorso, corpo, extra) {
  const r = await fetch(CLOUD_URL + percorso, {
    method: metodo, signal: AbortSignal.timeout(20000),
    headers: Object.assign({ apikey: CLOUD_KEY, Authorization: "Bearer " + CLOUD_KEY, "Content-Type": "application/json" }, extra || {}),
    body: corpo === undefined ? undefined : JSON.stringify(corpo) });
  const testo = await r.text();
  let dati = null; try { dati = testo ? JSON.parse(testo) : null; } catch (_) {}
  return { ok: r.ok, stato: r.status, dati };
}
function giornataDi(t, riga) {
  if (t === "servizi") return riga;
  if (t === "attivita") return tab("servizi").get(String(riga.servizio_id)) || null;
  if (t === "rulli") return tab("servizi").get(String(riga.servizio_id)) || null;
  if (t === "foto") { const r = tab("rulli").get(String(riga.rullo_id)); return r ? tab("servizi").get(String(r.servizio_id)) || null : null; }
  return null;
}
const chiaveFile = url => { const m = /\/storage\/v1\/object\/public\/([^/]+)\/([^?]+)/.exec(String(url || "")); return m ? [m[1], decodeURIComponent(m[2])] : null; };
const qFileInviato = db.prepare("SELECT 1 FROM inviati WHERE tab = 'file' AND chiave = ?");
const fileInviato = (bucket, p) => !!qFileInviato.get(bucket + "/" + p);

/* Il cloud (PostgREST) rifiuta un invio di più righe se non hanno TUTTE le stesse
   colonne: ogni riga esce quindi con tutte le colonne, quelle mancanti col loro valore
   predefinito (o vuote). */
const PREDEF_CLOUD = { stampe: 0, esportata: false, omaggi: 0, scarti: 0, copie: 1, conserva: false, richiesta_originale: false,
                       da_stampare: false, ultimo_num: 0, file: 0, file_venduti: 0, quante: 1 };
function rigaPerCloud(t, riga) {
  const out = {};
  for (const c of COLONNE[t]) out[c] = riga[c] !== undefined && riga[c] !== null ? riga[c] : (c in PREDEF_CLOUD ? PREDEF_CLOUD[c] : null);
  if (t === "servizi" && riga.solo_locale === undefined) out.solo_locale = true;
  if (t === "servizi") out.id = giornataCloud(riga.id);
  if (t === "rulli" || t === "attivita") out.servizio_id = giornataCloud(riga.servizio_id);
  if (t === "foto") {
    const g = giornataDi("foto", riga);
    const soloNumeri = !g || g.solo_locale !== false;
    for (const c of ["mini_url", "anteprima_url"]) {
      const k = chiaveFile(riga[c]);
      out[c] = (!soloNumeri && k && fileInviato(k[0], k[1])) ? CLOUD_URL + String(riga[c]).replace(/^https?:\/\/[^/]+/, "") : null;
    }
    out.originale_url = (!soloNumeri && riga.originale_url && fileInviato("originali", riga.originale_url)) ? riga.originale_url : null;
    if (soloNumeri) { out.richiesta_originale = false; out.da_stampare = false; }
  }
  return out;
}

async function inviaServizio(riga) {
  // c'è già sul cloud una giornata di questa sede in questa data? allora è quella
  // (solo la prima volta: dopo, la giornata trovata sul cloud è quella mandata da qui)
  if (!qMappa.get("servizi", String(riga.id)) && !inviato("servizi", riga.id)) {
    const r = await cloudJson("GET", `/rest/v1/servizi?select=id&sede_id=eq.${riga.sede_id}&data_servizio=eq.${riga.data_servizio}`);
    if (!r.ok) return false;
    if (r.dati && r.dati.length) {
      // esisteva già (anche con lo stesso identificativo): è "del cloud", non la si cancella né la si marca
      qSetMappa.run("servizi", String(riga.id), String(r.dati[0].id));
      console.log(`  ↔ giornata ${riga.data_servizio}: sul cloud esisteva già, mi aggancio a quella`);
    }
  }
  const corpo = rigaPerCloud("servizi", riga);
  if (qMappa.get("servizi", String(riga.id))) delete corpo.solo_locale;   // la giornata è del cloud: non la si cambia
  const r = await cloudJson("POST", "/rest/v1/servizi?on_conflict=id", [corpo], { Prefer: "resolution=merge-duplicates,return=minimal" });
  return r.ok;
}
async function inviaRullo(riga) {
  const g = giornataCloud(riga.servizio_id);
  const r = await cloudJson("GET", `/rest/v1/rulli?select=id&servizio_id=eq.${g}&lettera=eq.${encodeURIComponent(riga.lettera)}`);
  if (!r.ok) return false;
  if (r.dati && r.dati.length && String(r.dati[0].id) !== String(riga.id)) {
    if (!conflittiRulli.has(riga.id)) {
      conflittiRulli.add(riga.id);
      const sv = tab("servizi").get(String(riga.servizio_id));
      const msg = `⚠ Rullo ${riga.lettera} del ${sv ? sv.data_servizio : "?"}: sul cloud c'è già un rullo ${riga.lettera} fatto da un'altra parte. NON lo mando per non mescolarli.`;
      statoCloud.avvisi.push(msg); console.log("  " + msg);
    }
    return "conflitto";
  }
  const w = await cloudJson("POST", "/rest/v1/rulli?on_conflict=id", [rigaPerCloud("rulli", riga)], { Prefer: "resolution=merge-duplicates,return=minimal" });
  return w.ok;
}

// toglie dal cloud tutti i file sotto una cartella (es. le anteprime di una giornata)
async function svuotaCloud(bucket, prefisso) {
  for (let giro = 0; giro < 50; giro++) {
    const l = await cloudJson("POST", `/storage/v1/object/list/${bucket}`, { prefix: prefisso, limit: 1000, offset: 0 });
    const nomi = (l.ok && Array.isArray(l.dati) ? l.dati : []).filter(x => x.id !== null).map(x => prefisso + "/" + x.name);
    if (!nomi.length) return;
    const r = await cloudJson("DELETE", `/storage/v1/object/${bucket}`, { prefixes: nomi });
    if (!r.ok) return;
  }
}

let specchioInCorso = false;
async function specchio() {
  if (specchioInCorso) return;
  specchioInCorso = true;
  try {
    const ping = await cloudJson("GET", "/rest/v1/sedi?select=id&limit=1").catch(() => ({ ok: false }));
    statoCloud.online = !!ping.ok;
    if (!ping.ok) return;
    statoCloud.ultimoContatto = ora();
    let nRighe = 0, nFile = 0, nCanc = 0;
    // ogni 2 minuti: sedi nuove o cancellate sul cloud
    if (Date.now() - (statoCloud.ultimeSedi || 0) > Number(process.env.FAY_SEDI_MS || 120000)) { statoCloud.ultimeSedi = Date.now(); await scaricaDalCloud(true); }

    const coda = db.prepare("SELECT tab, chiave, op, ver FROM da_inviare").all();
    // 1) aggiornamenti, nell'ordine delle dipendenze
    for (const t of ORDINE) {
      const righe = coda.filter(x => x.tab === t && x.op === "up");
      const gruppo = [];
      for (const v of righe) {
        const riga = tab(t).get(v.chiave);
        if (!riga) { qFatto.run(t, v.chiave, v.ver); continue; }
        if (t === "sedi") {
          const r = await cloudJson("POST", "/rest/v1/sedi?on_conflict=id", [rigaPerCloud("sedi", riga)], { Prefer: "resolution=merge-duplicates,return=minimal" });
          if (r.ok) { qSegnaInviato.run(t, v.chiave); qFatto.run(t, v.chiave, v.ver); }
          else if (r.dati && String(r.dati.code) === "23505") {
            // stesso nome di una sede del cloud: la si unisce a quella al prossimo avvio
            console.log(`  ⚠ La sede "${riga.nome}" esiste già sul cloud con un altro identificativo: verrà unita al prossimo avvio con la linea.`);
          }
          continue;
        }
        const g = giornataDi(t, riga);
        if (!g) { qFatto.run(t, v.chiave, v.ver); continue; }
        if (t !== "servizi" && !inviato("servizi", g.id)) continue;      // prima deve salire la giornata
        if (t === "servizi") {
          if (!inviato("sedi", riga.sede_id)) continue;
          if (await inviaServizio(riga)) { qSegnaInviato.run(t, v.chiave); qFatto.run(t, v.chiave, v.ver); }
          continue;
        }
        if (t === "rulli") {
          const e = await inviaRullo(riga);
          if (e === true) { qSegnaInviato.run(t, v.chiave); qFatto.run(t, v.chiave, v.ver); }
          continue;
        }
        if (t === "foto" && (conflittiRulli.has(riga.rullo_id) || !inviato("rulli", riga.rullo_id))) continue;
        gruppo.push({ v, corpo: rigaPerCloud(t, riga) });
      }
      for (let i = 0; i < gruppo.length; i += 300) {
        const pezzo = gruppo.slice(i, i + 300);
        const pref = t === "attivita" ? "resolution=ignore-duplicates,return=minimal" : "resolution=merge-duplicates,return=minimal";
        const r = await cloudJson("POST", `/rest/v1/${t}?on_conflict=id`, pezzo.map(x => x.corpo), { Prefer: pref });
        if (!r.ok) { console.log(`  ⚠ invio ${t} non riuscito (${r.stato}): ${r.dati && r.dati.message || ""}`); break; }
        inTransazione(() => pezzo.forEach(x => { qSegnaInviato.run(t, x.v.chiave); qFatto.run(t, x.v.chiave, x.v.ver); }));
        nRighe += pezzo.length;
      }
    }
    /* 2) cancellazioni fatte qui (svuota giornata, cancella sede…): si ripetono sul cloud.
          Solo righe che il cloud ha perché mandate da qui, più le SEDI: "Cancella sede"
          vale ovunque, come se l'avessi fatto dal sito (lassù spariscono anche le sue
          giornate e i suoi file). Le giornate del cloud a cui ci si era agganciati invece
          non si cancellano da qui. */
    for (const t of [...ORDINE].reverse()) {
      const lista = [];
      for (const v of coda.filter(x => x.tab === t && x.op === "del")) {
        if (!inviato(t, v.chiave)) { qFatto.run(t, v.chiave, v.ver); continue; }
        if (t === "servizi" && qMappa.get("servizi", v.chiave)) { qTogliInviato.run(t, v.chiave); qFatto.run(t, v.chiave, v.ver); continue; }
        lista.push(v);
      }
      if (t === "sedi") {
        for (const v of lista) {
          const g = await cloudJson("GET", `/rest/v1/servizi?select=id&sede_id=eq.${v.chiave}`);
          if (!g.ok) break;
          for (const sv of (g.dati || [])) for (const b of ["anteprime", "originali"]) await svuotaCloud(b, String(sv.id));
          const r = await cloudJson("DELETE", `/rest/v1/sedi?id=eq.${v.chiave}`, undefined, { Prefer: "return=minimal" });
          if (r.ok) { qTogliInviato.run(t, v.chiave); qFatto.run(t, v.chiave, v.ver); nCanc++; }
        }
        continue;
      }
      for (let i = 0; i < lista.length; i += 150) {
        const pezzo = lista.slice(i, i + 150);
        if (t === "servizi") for (const v of pezzo) for (const b of ["anteprime", "originali"]) await svuotaCloud(b, v.chiave);
        const r = await cloudJson("DELETE", `/rest/v1/${t}?id=in.(${pezzo.map(v => v.chiave).join(",")})`, undefined, { Prefer: "return=minimal" });
        if (!r.ok) break;
        inTransazione(() => pezzo.forEach(v => { qTogliInviato.run(t, v.chiave); qFatto.run(t, v.chiave, v.ver); }));
        nCanc += pezzo.length;
      }
    }
    // 3) file delle giornate "con linea": prima le anteprime, poi gli originali (pochi per giro)
    const files = db.prepare("SELECT bucket, percorso, ver FROM file_da_inviare ORDER BY CASE bucket WHEN 'anteprime' THEN 0 ELSE 1 END LIMIT 40").all();
    for (const f of files) {
      const idGiornata = f.percorso.split("/")[0];
      const g = tab("servizi").get(idGiornata);
      const fatto = () => db.prepare("DELETE FROM file_da_inviare WHERE bucket = ? AND percorso = ? AND ver = ?").run(f.bucket, f.percorso, f.ver);
      if (!g || g.solo_locale !== false) { fatto(); continue; }          // giornata "solo numeri": i file restano qui
      let dati;
      try { dati = fs.readFileSync(percorsoFile(f.bucket, f.percorso)); } catch (_) { fatto(); continue; }
      const r = await fetch(`${CLOUD_URL}/storage/v1/object/${f.bucket}/${f.percorso.split("/").map(encodeURIComponent).join("/")}`, {
        method: "POST", signal: AbortSignal.timeout(120000),
        headers: { apikey: CLOUD_KEY, Authorization: "Bearer " + CLOUD_KEY, "x-upsert": "true",
                   "Content-Type": TIPI[path.extname(f.percorso).toLowerCase()] || "application/octet-stream" },
        body: dati }).catch(() => null);
      if (!r || !r.ok) break;
      nFile++;
      inTransazione(() => {
        fatto();
        qSegnaInviato.run("file", f.bucket + "/" + f.percorso);
        // le foto che usano questo file vanno rimandate: ora l'indirizzo si può scrivere
        for (const ft of tab("foto").values()) {
          const usa = f.bucket === "originali" ? ft.originale_url === f.percorso
                    : [ft.mini_url, ft.anteprima_url].some(u => { const k = chiaveFile(u); return k && k[0] === f.bucket && k[1] === f.percorso; });
          if (usa) stSegna.run("foto", chiaveDi("foto", ft), "up");
        }
      });
    }
    if (nRighe || nFile || nCanc) console.log(`  ↑ ${new Date().toLocaleTimeString("it-IT")} cloud aggiornato: ${nRighe} righe` + (nFile ? `, ${nFile} file` : "") + (nCanc ? `, ${nCanc} cancellazioni` : ""));
  } catch (e) {
    console.log("  ⚠ specchio:", e.message);
  } finally {
    specchioInCorso = false;
  }
}
function prepariSpecchio() {
  // la prima volta con questa versione: tutto quello che c'è già va mandato
  if (!db.prepare("SELECT v FROM stato WHERE k = 'specchio_avviato'").get()) {
    inTransazione(() => {
      for (const t of ORDINE) for (const [k] of tab(t)) stSegna.run(t, k, "up");
      for (const g of tab("servizi").values()) if (g.solo_locale === undefined) { g.solo_locale = true; salva("servizi", g); }
      db.prepare("INSERT INTO stato (k, v) VALUES ('specchio_avviato', ?)").run(ora());
    });
  }
  const ogni = Number(process.env.FAY_SPECCHIO_MS || 20000);
  setInterval(specchio, ogni);
  setTimeout(specchio, Math.min(3000, ogni));
}

/* ---------------- server ---------------- */
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://centrale");
  if (process.env.FAY_LOG) res.on("finish", () => { if (res.statusCode >= 400) console.log("  [" + res.statusCode + "]", req.method, url.pathname + url.search); });
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,PATCH,PUT,DELETE,HEAD,OPTIONS");
  res.setHeader("Access-Control-Expose-Headers", "Content-Range");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  try {
    if (url.pathname.startsWith("/rest/v1/")) return await rest(req, res, url);
    if (url.pathname.startsWith("/storage/v1/")) return await storage(req, res, url);
    if (url.pathname.startsWith("/auth/v1/") || url.pathname.startsWith("/realtime/v1/")) return json(res, 404, { message: "non disponibile sul PC centrale" });
    if (url.pathname === "/stato") return json(res, 200, { centrale: true, ora: ora(), foto: tab("foto").size,
      cloud: statoCloud.online, ultimoContatto: statoCloud.ultimoContatto,
      daInviare: db.prepare("SELECT COUNT(*) AS n FROM da_inviare").get().n,
      fileDaInviare: db.prepare("SELECT COUNT(*) AS n FROM file_da_inviare").get().n, avvisi: statoCloud.avvisi });
    if (url.pathname === "/" ) { res.writeHead(302, { Location: "/pc.html" }); return res.end(); }
    if (url.pathname.startsWith("/lib/")) return serviFile(res, path.join(LIB, path.basename(url.pathname)));
    const pagina = path.join(PAGINE, path.basename(url.pathname));
    if (/\.html$/.test(pagina) && fs.existsSync(pagina)) {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(adattaPagina(fs.readFileSync(pagina, "utf8")));
    }
    return json(res, 404, { message: "non trovato" });
  } catch (e) {
    if (!e.stato) console.error("errore", req.method, url.pathname, e);
    if (!res.headersSent) json(res, e.stato || 500, { code: e.code || "500", message: e.message, details: null, hint: null });
    else res.end();
  }
});
// il tempo reale di Supabase non c'è: la richiesta di collegamento si chiude e pc.html usa il controllo periodico
server.on("upgrade", (req, socket) => socket.destroy());

function indirizzi() {
  const out = [];
  for (const lista of Object.values(os.networkInterfaces())) for (const a of lista || [])
    if (a.family === "IPv4" && !a.internal) out.push(a.address);
  return out;
}

if (process.env.FAY_TEST !== "1") await aggiornaPagine();
if (process.env.FAY_TEST !== "1" || process.env.FAY_CLOUD_URL) { await scaricaDalCloud(); prepariSpecchio(); }
server.listen(PORTA, "0.0.0.0", () => {
  console.log("");
  console.log("  FAY LIVE — PC CENTRALE acceso");
  console.log(`  Su questo PC:   http://localhost:${PORTA}/pc.html`);
  for (const ip of indirizzi()) console.log(`  Dalle postazioni: http://${ip}:${PORTA}/pc.html`);
  console.log(`  Dati e foto in: ${DATI}`);
  console.log(`  Originali leggibili (sede, giorno, rullo, codice): ${ARCHIVIO}`);
  console.log("  Non chiudere questa finestra finché si lavora.");
  console.log("");
  setTimeout(riordinaArchivio, 3000);
  setInterval(riordinaArchivio, 10 * 60 * 1000);
  // apre da solo la pagina su questo PC
  // (non quando parte dall'icona: lì apre già il Chrome con la stampa diretta, niente doppia pagina)
  if (process.platform === "win32" && process.env.FAY_TEST !== "1" && process.env.FAY_NO_APRI !== "1") exec(`start "" "http://localhost:${PORTA}/pc.html"`);
});
server.on("error", e => {
  if (e.code === "EADDRINUSE") console.log(`\n  ⚠ Il PC centrale è GIÀ acceso (porta ${PORTA} occupata): chiudi l'altra finestra nera e riprova.\n`);
  else console.log("\n  ⚠ Errore di avvio:", e.message, "\n");
});
