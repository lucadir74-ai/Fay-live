/* Fay Live — invio digitali, PASSO 2 di 3: carica un gruppetto di foto.
 *
 * Va nel repo in:  /api/invia-pezzo.js
 *
 * Il tablet chiama questa funzione più volte, un gruppetto per volta (6 foto), usando
 * transferid/transferkey/transferurl ricevuti da /api/invia-apri. Ogni chiamata dura
 * pochi secondi e non arriva mai vicino al limite di Vercel: è questo che toglie il 504.
 *
 * Dentro il gruppetto le foto vengono caricate 3 alla volta invece che in fila
 * (Filemail consiglia di non superare 4 richieste in parallelo).
 */

export const config = { maxDuration: 60 };

const MAX_PER_CHIAMATA = 8;   // il tablet ne manda 6: questo è solo un tetto di sicurezza
const IN_PARALLELO = 3;

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ errore: "Metodo non consentito" });

  const key = (process.env.FILEMAIL_API_KEY || "").trim();
  if (!key) return res.status(500).json({ errore: "FILEMAIL_API_KEY non configurata su Vercel" });

  const { transferid, transferkey, transferurl, files } = req.body || {};
  if (!transferid || !transferkey || !transferurl)
    return res.status(400).json({ errore: "Trasferimento non indicato" });
  if (!Array.isArray(files) || !files.length)
    return res.status(400).json({ errore: "Nessun file da caricare" });
  if (files.length > MAX_PER_CHIAMATA)
    return res.status(400).json({ errore: `Troppi file in un gruppetto (max ${MAX_PER_CHIAMATA})` });

  /* L'indirizzo di caricamento arriva dal tablet: va controllato che sia davvero di
     Filemail, altrimenti questa funzione potrebbe essere usata per spedire i file
     di Supabase a un server qualsiasi. */
  let dest;
  try { dest = new URL(transferurl); } catch { return res.status(400).json({ errore: "Indirizzo di caricamento non valido" }); }
  if (dest.protocol !== "https:" || !/(^|\.)filemail\.com$/i.test(dest.hostname))
    return res.status(400).json({ errore: "Indirizzo di caricamento non ammesso" });

  /* Stesso controllo di /api/invia: si accettano SOLO file del vostro progetto Supabase. */
  const host = (process.env.SUPABASE_HOST || "")
    .trim().replace(/^["']|["']$/g, "")
    .replace(/^https?:\/\//i, "")
    .replace(/\/.*$/, "")
    .toLowerCase();

  for (const f of files) {
    let u;
    try { u = new URL(f.url); } catch { return res.status(400).json({ errore: "Indirizzo file non valido" }); }
    const h = u.hostname.toLowerCase();
    const ammesso = host ? (h === host) : /\.supabase\.co$/.test(h);
    if (u.protocol !== "https:" || !ammesso)
      return res.status(400).json({
        errore: "Indirizzo file non ammesso",
        dettaglio: `il file arriva da "${h}", mentre SUPABASE_HOST su Vercel vale "${host || "(non impostata)"}".`
      });
  }

  async function caricaUna(f) {
    const giu = await fetch(f.url);
    if (!giu.ok) return { nome: f.nome, ok: false, motivo: "non più sul cloud" };
    const dati = Buffer.from(await giu.arrayBuffer());
    const q = new URLSearchParams({
      transferid, transferkey,
      thefilename: f.nome || "foto.jpg",
      chunks: "1", chunk: "0", chunksize: String(dati.length || 1)
    });
    for (let tent = 0; tent < 3; tent++) {
      const su = await fetch(transferurl + "?" + q.toString(), {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream", "User-Agent": "Fay Live" },
        body: dati
      });
      if (su.ok) return { nome: f.nome, ok: true };
      // 406/449 = riprova più tardi, è previsto da Filemail
      if (su.status === 406 || su.status === 449) { await new Promise(r => setTimeout(r, 800)); continue; }
      return { nome: f.nome, ok: false, motivo: "HTTP " + su.status };
    }
    return { nome: f.nome, ok: false, motivo: "Filemail occupato" };
  }

  try {
    const esiti = [];
    for (let i = 0; i < files.length; i += IN_PARALLELO) {
      const gruppo = files.slice(i, i + IN_PARALLELO);
      const r = await Promise.all(gruppo.map(f =>
        caricaUna(f).catch(e => ({ nome: f.nome, ok: false, motivo: String(e && e.message || e) }))
      ));
      esiti.push(...r);
    }
    return res.status(200).json({
      ok: true,
      caricate: esiti.filter(e => e.ok).map(e => e.nome),
      saltate: esiti.filter(e => !e.ok).map(e => ({ nome: e.nome, motivo: e.motivo }))
    });
  } catch (err) {
    return res.status(500).json({ errore: "Caricamento non riuscito", dettaglio: String(err && err.message || err) });
  }
}
