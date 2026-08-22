/* Fay Live — invio digitali, PASSO 1 di 3: apre il trasferimento su Filemail.
 *
 * Va nel repo in:  /api/invia-apri.js
 *
 * Perché l'invio è spezzato in tre chiamate:
 *   la vecchia /api/invia faceva tutto in una volta sola — apriva il trasferimento,
 *   scaricava e ricaricava OGNI foto in fila, poi chiudeva. Con più di ~20 foto
 *   superava i 60 secondi concessi a una funzione su Vercel e il tablet riceveva
 *   un 504 senza che partisse niente. Filemail però tiene aperto il trasferimento
 *   con transferid/transferkey: si può quindi aprire qui, caricare a gruppetti con
 *   /api/invia-pezzo (una chiamata breve per gruppetto) e chiudere con
 *   /api/invia-chiudi. Nessuna singola chiamata arriva più vicina al limite.
 *
 * La vecchia /api/invia NON va cancellata: la usa ancora il PC.
 *
 * Variabili d'ambiente su Vercel: le stesse già impostate per /api/invia
 *   FILEMAIL_API_KEY, FILEMAIL_EMAIL, FILEMAIL_PASSWORD,
 *   FILEMAIL_GIORNI (facoltativa), FILEMAIL_MITTENTE (facoltativa)
 */

const API = "https://api-public.filemail.com";

export const config = { maxDuration: 30 };

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ errore: "Metodo non consentito" });

  const key = (process.env.FILEMAIL_API_KEY || "").trim();
  if (!key) return res.status(500).json({ errore: "FILEMAIL_API_KEY non configurata su Vercel" });

  const { email, oggetto, messaggio } = req.body || {};
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))
    return res.status(400).json({ errore: "Email non valida" });

  const intestazioni = { "X-API-Key": key, "Content-Type": "application/json" };
  const conChiave = (url) => url + (url.includes("?") ? "&" : "?") + "apikey=" + encodeURIComponent(key);

  const giorni = parseInt(process.env.FILEMAIL_GIORNI || "7", 10);
  const mittente = (process.env.FILEMAIL_MITTENTE || "").trim();
  const msg = messaggio || ("Ecco le tue foto. Il link resta attivo " + giorni + " giorni.");
  const sub = oggetto || "Le tue foto";
  const problemi = [];

  try {
    /* Filemail vuole un utente autenticato: la sola chiave API non basta e la
       initialize risponde "please login". */
    let logintoken = null;
    const utente = (process.env.FILEMAIL_EMAIL || "").trim();
    const pwd = process.env.FILEMAIL_PASSWORD || "";
    if (utente && pwd) {
      try {
        const q = new URLSearchParams({ apikey: key, username: utente, password: pwd, source: "Web" });
        const lr = await fetch("https://www.filemail.com/api/authentication/login?" + q.toString(), {
          headers: { "User-Agent": "Fay Live" }
        });
        const lj = await lr.json().catch(() => ({}));
        logintoken = lj?.logintoken || lj?.data?.logintoken || null;
        if (!logintoken) problemi.push("login: " + (lj?.errormessage || lj?.responsestatus || ("HTTP " + lr.status)));
      } catch (e) { problemi.push("login: " + String(e && e.message || e)); }
    } else {
      problemi.push("login: FILEMAIL_EMAIL o FILEMAIL_PASSWORD non configurate su Vercel");
    }

    async function initJson() {
      const r = await fetch(conChiave(API + "/transfer/initialize"), {
        method: "POST", headers: intestazioni,
        body: JSON.stringify({
          logintoken: logintoken || undefined,
          to: [email], from: mittente || undefined, subject: sub, message: msg,
          days: giorni, confirmation: false, notify: false, sourcedetails: "Fay Live"
        })
      });
      const j = await r.json().catch(() => ({}));
      if (r.ok && j?.data?.transferid && (j.responsestatus === undefined || j.responsestatus === "OK")) return j.data;
      problemi.push("JSON: " + (j?.errormessage || j?.responsestatus || ("HTTP " + r.status)));
      return null;
    }

    async function initClassica() {
      const corpo = new URLSearchParams({
        apikey: key, to: email, subject: sub, message: msg,
        days: String(giorni), confirmation: "false", notify: "false"
      });
      if (mittente) corpo.set("from", mittente);
      if (logintoken) corpo.set("logintoken", logintoken);
      const r = await fetch("https://www.filemail.com/api/transfer/initialize", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Fay Live" },
        body: corpo.toString()
      });
      const j = await r.json().catch(() => ({}));
      const dati = j?.data || j;
      if (r.ok && dati?.transferid && (j.responsestatus === undefined || j.responsestatus === "OK")) return dati;
      problemi.push("classica: " + (j?.errormessage || j?.responsestatus || ("HTTP " + r.status)));
      return null;
    }

    const dati = (await initJson()) || (await initClassica());
    if (!dati) {
      return res.status(502).json({
        errore: "Filemail non ha aperto il trasferimento",
        dettaglio: problemi.join("  |  ")
      });
    }

    return res.status(200).json({
      ok: true,
      transferid: dati.transferid,
      transferkey: dati.transferkey,
      transferurl: dati.transferurl,
      logintoken                       // serve al passo 3 per chiudere il trasferimento
    });

  } catch (err) {
    return res.status(500).json({ errore: "Apertura non riuscita", dettaglio: String(err && err.message || err) });
  }
}
