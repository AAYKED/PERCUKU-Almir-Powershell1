// Recupere le HTML *rendu* d'une page via un vrai navigateur Chromium (Playwright).
// Sert a contourner les protections anti-robot (DataDome/Akamai) de Fnac/Carrefour
// qui refusent les simples requetes HTTP mais laissent passer un navigateur executant JS.
//
// Usage : node fetch-rendered.mjs <url>
//   -> ecrit le HTML de la page sur la sortie standard.
//   -> code de sortie 0 si OK, non nul sinon (message sur la sortie d'erreur).
//
// Variables d'environnement :
//   RENDER_TIMEOUT_MS  : delai de navigation (defaut 45000)
//   RENDER_WAIT_MS     : attente supplementaire apres chargement (defaut 3000)

import { chromium } from 'playwright';

const url = process.argv[2];
const navTimeout = parseInt(process.env.RENDER_TIMEOUT_MS || '45000', 10);
const extraWait = parseInt(process.env.RENDER_WAIT_MS || '3000', 10);

if (!url) {
  console.error('URL manquante. Usage : node fetch-rendered.mjs <url>');
  process.exit(2);
}
if (!/^https:\/\//i.test(url)) {
  console.error('URL non HTTPS refusee : ' + url);
  process.exit(2);
}

const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({
    userAgent:
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    locale: 'fr-FR',
    timezoneId: 'Europe/Paris',
    viewport: { width: 1366, height: 768 },
    extraHTTPHeaders: { 'Accept-Language': 'fr-FR,fr;q=0.9,en;q=0.8' },
  });
  const page = await context.newPage();
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: navTimeout });

  // Laisser le temps au challenge JS eventuel et au rendu du prix.
  if (extraWait > 0) await page.waitForTimeout(extraWait);
  try {
    await page.waitForLoadState('networkidle', { timeout: 8000 });
  } catch {
    /* pas grave si le reseau n'est jamais totalement inactif */
  }

  const html = await page.content();
  process.stdout.write(html);
} catch (e) {
  console.error('Echec du rendu : ' + (e && e.message ? e.message : String(e)));
  process.exitCode = 1;
} finally {
  await browser.close();
}
