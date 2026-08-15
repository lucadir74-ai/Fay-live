/* Fay Live — invio dei file digitali al cliente tramite Filemail.
 *
 * Va messo nel repo in:  /api/invia.js   (Vercel lo pubblica come /api/invia)
 *
 * Perché passa da qui e non dal browser del PC:
 *  - le foto viaggiano da Supabase a Filemail fra due server, senza scendere
 *    e risalire dall'hotspot della postazione;
 *  - funziona da qualsiasi postazione, anche se PC1 è spento;
 *  - la chiave API resta sul server e non finisce nel sorgente della pagina.
 *
 * Variabili d'ambiente richieste su Vercel (Settings → Environment Variables):
 *  FILEMAIL_API_KEY   la chiave presa dal pannello Filemail
 *  SUPABASE_HOST      solo il dominio del progetto, es. abcdefgh.supabase.co
 *                     (serve a impedire che questo endpoint spedisca file altrui)
 *  FILEMAIL_GIORNI    facoltativa, giorni di validità del link (default 7)
 *  FILEMAIL_MITTENTE  facoltativa, email mostrata come mittente
 */

const API = "https://api-public.filemail.com";

export const config = { maxDuration: 60 };   // il download+upload richiede tempo

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ errore: "Metodo non consentito" });

  const key = (process.env.FILEMAIL_API_KEY || "").trim();
  if (!key)  return res.status(500).json({ errore: "FILEMAIL_API_KEY non configurata su Vercel" });

  /* Il valore incollato a mano su Vercel arriva spesso con https://, una barra finale,
     spazi o un a capo invisibile: prima si confrontava alla lettera e l'invio veniva
     rifiutato anche quando il dominio era quello giusto. Qui si ripulisce. */
  const host = (process.env.SUPABASE_HOST || "")
    .trim().replace(/^["']|["']$/g, "")
    .replace(/^https?:\/\//i, "")
    .replace(/\/.*$/, "")
    .toLowerCase();

  const { email, files, oggetto, messaggio } = req.body || {};
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))
    return res.status(400).json({ errore: "Email non valida" });
  if (!Array.isArray(files) || !files.length)
    return res.status(400).json({ errore: "Nessun file da inviare" });
  if (files.length > 60)
    return res.status(400).json({ errore: "Troppi file in un solo invio (max 60)" });

  // Si accettano SOLO indirizzi del vostro progetto Supabase: senza questo controllo
  // chiunque conosca l'indirizzo di questa funzione potrebbe usarla per spedire file qualsiasi.
  for (const f of files) {
    let u;
    try { u = new URL(f.url); } catch { return res.status(400).json({ errore: "Indirizzo file non valido" }); }
    const h = u.hostname.toLowerCase();
    // se SUPABASE_HOST non è impostata si accetta comunque solo Supabase, mai domini qualsiasi
    const ammesso = host ? (h === host) : /\.supabase\.co$/.test(h);
    if (u.protocol !== "https:" || !ammesso)
      return res.status(400).json({
        errore: "Indirizzo file non ammesso",
        dettaglio: `il file arriva da "${h}", mentre SUPABASE_HOST su Vercel vale "${host || "(non impostata)"}". ` +
                   `Se i due domini coincidono, il deploy sta ancora usando il valore vecchio: rifai un Redeploy.`
      });
  }

  const intestazioni = { "X-API-Key": key, "Content-Type": "application/json" };
  const conChiave = (url) => url + (url.includes("?") ? "&" : "?") + "apikey=" + encodeURIComponent(key);

  try {
    // 1) apre il trasferimento
    const giorni = parseInt(process.env.FILEMAIL_GIORNI || "7", 10);
    const initRes = await fetch(conChiave(API + "/transfer/initialize"), {
      method: "POST",
      headers: intestazioni,
      body: JSON.stringify({
        to: [email],
        from: process.env.FILEMAIL_MITTENTE || undefined,
        subject: oggetto || "Le tue foto",
        message: messaggio || "Ecco le tue foto. Il link resta attivo " + giorni + " giorni.",
        days: giorni,
        confirmation: false,
        notify: false,
        sourcedetails: "Fay Live"
      })
    });
    const init = await initRes.json();
    if (!initRes.ok || !init?.data?.transferid) {
      return res.status(502).json({ errore: "Filemail non ha aperto il trasferimento",
                                    dettaglio: init?.errormessage || init?.responsestatus || null });
    }
    const { transferid, transferkey, transferurl } = init.data;

    // 2) scarica ogni foto da Supabase e la passa a Filemail
    //    (le foto pesano ~2 MB: sotto i 50 MB non serve spezzettarle)
    const inviati = [];
    for (const f of files) {
      const giu = await fetch(f.url);
      if (!giu.ok) continue;                      // foto non più sul cloud: la salto
      const dati = Buffer.from(await giu.arrayBuffer());
      const q = new URLSearchParams({
        transferid, transferkey,
        thefilename: f.nome || "foto.jpg",
        chunks: "1", chunk: "0", chunksize: String(dati.length || 1)
      });
      let ok = false;
      for (let tent = 0; tent < 3 && !ok; tent++) {
        const su = await fetch(transferurl + "?" + q.toString(), {
          method: "POST",
          headers: { "Content-Type": "application/octet-stream", "User-Agent": "Fay Live" },
          body: dati
        });
        if (su.ok) ok = true;
        else if (su.status === 406 || su.status === 449) await new Promise(r => setTimeout(r, 800));
        else break;
      }
      if (ok) inviati.push(f.nome);
    }

    if (!inviati.length) {
      return res.status(502).json({ errore: "Nessuna foto è stata caricata su Filemail" });
    }

    // 3) chiude il trasferimento: è qui che parte la mail al cliente
    const endRes = await fetch(conChiave(API + "/transfer/complete"), {
      method: "PUT",
      headers: intestazioni,
      body: JSON.stringify({ transferid, transferkey })
    });
    const fine = await endRes.json();
    if (!endRes.ok) {
      return res.status(502).json({ errore: "Trasferimento non completato",
                                    dettaglio: fine?.errormessage || fine?.responsestatus || null });
    }

    return res.status(200).json({
      ok: true,
      inviate: inviati.length,
      saltate: files.length - inviati.length,
      link: fine?.data?.downloadurl || null
    });

  } catch (err) {
    return res.status(500).json({ errore: "Invio non riuscito", dettaglio: String(err && err.message || err) });
  }
}
