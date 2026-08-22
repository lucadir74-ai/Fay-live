/* Fay Live — invio digitali, PASSO 3 di 3: chiude il trasferimento.
 *
 * Va nel repo in:  /api/invia-chiudi.js
 *
 * È qui che parte la mail al cliente: finché il trasferimento non viene chiuso,
 * le foto sono su Filemail ma nessuno riceve niente.
 */

const API = "https://api-public.filemail.com";

export const config = { maxDuration: 30 };

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ errore: "Metodo non consentito" });

  const key = (process.env.FILEMAIL_API_KEY || "").trim();
  if (!key) return res.status(500).json({ errore: "FILEMAIL_API_KEY non configurata su Vercel" });

  const { transferid, transferkey, logintoken } = req.body || {};
  if (!transferid || !transferkey)
    return res.status(400).json({ errore: "Trasferimento non indicato" });

  const intestazioni = { "X-API-Key": key, "Content-Type": "application/json" };
  const conChiave = (url) => url + (url.includes("?") ? "&" : "?") + "apikey=" + encodeURIComponent(key);
  const problemi = [];

  /* Come per l'apertura si provano tutte e due le vie: un trasferimento aperto con
     l'API classica non si chiude su api-public, e viceversa. */
  async function completeJson() {
    const r = await fetch(conChiave(API + "/transfer/complete"), {
      method: "PUT", headers: intestazioni,
      body: JSON.stringify({ transferid, transferkey, logintoken: logintoken || undefined })
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok && (j.responsestatus === undefined || String(j.responsestatus).toUpperCase() === "OK")) return j;
    problemi.push("JSON: " + (j?.errormessage || j?.responsestatus || ("HTTP " + r.status)));
    return null;
  }

  async function completeClassica() {
    const corpo = new URLSearchParams({ apikey: key, transferid, transferkey });
    if (logintoken) corpo.set("logintoken", logintoken);
    const r = await fetch("https://www.filemail.com/api/transfer/complete", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Fay Live" },
      body: corpo.toString()
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok && (j.responsestatus === undefined || String(j.responsestatus).toUpperCase() === "OK")) return j;
    problemi.push("classica: " + (j?.errormessage || j?.responsestatus || ("HTTP " + r.status)));
    return null;
  }

  try {
    const fine = (await completeJson()) || (await completeClassica());
    if (!fine) {
      return res.status(502).json({
        errore: "Trasferimento non completato",
        dettaglio: problemi.join("  |  ")
      });
    }
    return res.status(200).json({ ok: true, link: fine?.data?.downloadurl || null });
  } catch (err) {
    return res.status(500).json({ errore: "Chiusura non riuscita", dettaglio: String(err && err.message || err) });
  }
}
