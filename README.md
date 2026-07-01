# PromoAggregator

Agrégateur de **codes promo** et **suivi de prix avec alertes** en PowerShell. Périmètre actuel : **Amazon, Fnac, Carrefour**.

- **Codes promo** (Amazon, Fnac) : ne propose **que des codes valides**, filtre par pays, affiche les meilleures offres en repli. Catalogue JSON **éditable**.
- **Suivi de prix** (PS5 Pro & Slim sur Amazon, Fnac, Carrefour) : relève le prix, détecte **baisses et hausses**, et **t'alerte directement** (console, fichier d'alertes, webhook Discord/Slack et notification Windows si configurés).

## Lancer le script (PowerShell 7)

Le projet requiert **PowerShell 7** (`pwsh`), pas le « Windows PowerShell 5.1 » bleu. Vérifie/installe :

```powershell
pwsh --version            # doit afficher 7.x
winget install Microsoft.PowerShell   # si besoin (Windows)
```

Depuis le dossier du projet, dans un terminal **pwsh** :

```powershell
pwsh ./promo.ps1                 # rechercher des codes promo (mode interactif)
pwsh ./promo.ps1 -List           # lister les sites
pwsh ./Watch-Prices.ps1 -NoAlert # 1er lancement : enregistre les prix de reference
pwsh ./Watch-Prices.ps1          # lancements suivants : alerte si le prix bouge
pwsh ./Update-Promos.ps1 -Force  # rafraichir les codes promo
pwsh ./tests/Invoke-Checks.ps1   # lancer les tests
```

### Lancement en un double-clic (Windows, fichiers .bat)

Pas envie de taper des commandes ? Double-clique simplement l'un de ces fichiers à la racine du projet :

| Fichier | Ce qu'il fait |
|---------|---------------|
| **`1-Initialiser-Prix.bat`** | À lancer **une fois** : enregistre les prix actuels comme référence (sans alerte). |
| **`Suivi-Prix.bat`** | Relève les prix et **t'alerte** si un prix a bougé (baisse/hausse). |
| **`Codes-Promo.bat`** | Ouvre la recherche de codes promo (mode interactif). |
| **`Planifier-Automatique.bat`** | Programme le suivi **tout seul toutes les 6 h** (tâche Windows). |

Ces fichiers trouvent PowerShell 7 automatiquement et contournent la restriction d'exécution — rien à configurer. S'ils affichent que `pwsh` est introuvable, installe PowerShell 7 (`winget install Microsoft.PowerShell`) puis relance.

## Pourquoi cette architecture (orientée données)

Scraper « tous les sites du monde » en direct est fragile (les pages changent en permanence), souvent contraire aux conditions d'utilisation, et expose à des failles (code distant, données non fiables). La solution robuste et sûre retenue ici est **orientée données** :

- Une **source de vérité unique et éditable** : `data/promo-codes.json`.
- Une **validation stricte** à chaque chargement (schéma, dates, codes pays).
- Une **logique de validité** qui ne renvoie que les codes actifs et dans leur fenêtre de dates.
- Un **point d'extension** clair (voir plus bas) si tu veux brancher plus tard une récupération automatique par site, sans toucher au cœur.

## Structure du projet

```
promo.ps1                       Interface en ligne de commande (+ mode interactif)
src/PromoAggregator.psd1        Manifeste du module
src/PromoAggregator.psm1        Module : logique métier (validation, filtres, gestion)
data/promo-codes.json           CATALOGUE ÉDITABLE — tes sites, codes et offres
config/settings.json            Réglages (pays par défaut, régions restreintes)
config/sources.json             Flux JSON de mise à jour (à activer/ajouter)
config/scrapers.json            Sites à scraper par nom (Amazon, Fnac)
config/products.json            Produits suivis pour le prix (PS5 Pro/Slim)
data/price-history.json         Historique des prix (référence des alertes)
Update-Promos.ps1               Rafraîchit les codes promo (récup + fusion)
Watch-Prices.ps1                Relève les prix et déclenche les alertes
.github/workflows/              Cron : codes promo (3 j) + prix (quotidien)
tests/PromoAggregator.Tests.ps1 Suite de tests Pester
tests/Invoke-Checks.ps1         Vérificateur sans dépendance (si Pester indisponible)
```

## Prérequis

- PowerShell 7.0+ (`pwsh`).

## Utilisation

### Mode interactif (questionne sur l'article recherché)

```bash
pwsh ./promo.ps1
```

Il demande : l'article/site recherché, la catégorie, le pays, et si la Chine (et régions à accès restreint) doit être incluse. Si rien n'a de code valide, il affiche les meilleures offres et propose d'élargir la recherche au monde entier.

### Recherche directe

```bash
pwsh ./promo.ps1 -Query amazon -Country FR
pwsh ./promo.ps1 -Category electronique -Worldwide -IncludeChina
pwsh ./promo.ps1 -Category mode -Country CN
pwsh ./promo.ps1 -Worldwide -ExcludeRestricted   # monde entier, hors Chine/RU/IR/KP
```

| Paramètre            | Effet                                                            |
|----------------------|------------------------------------------------------------------|
| `-Query`             | Mot-clé (nom de site, identifiant, URL)                          |
| `-Category`          | Catégorie d'article (electronique, mode, livres, maison...)      |
| `-Country`           | `ALL` (monde) ou code ISO 2 lettres (`FR`, `CN`, `US`...)         |
| `-Worldwide`         | Force la recherche mondiale                                      |
| `-IncludeChina`      | Inclut explicitement la Chine et les régions à accès restreint   |
| `-ExcludeRestricted` | Exclut la Chine et les régions à accès restreint                 |
| `-List`              | Liste tous les sites et leur nombre de codes valides             |

### Le filtre « Chine / monde entier »

- `data/promo-codes.json` : chaque site déclare ses pays (`"countries": ["CN"]`, ou `["ALL"]` pour mondial).
- `config/settings.json` : `restrictedRegions` liste les régions à accès restreint (par défaut `CN, RU, IR, KP`) et `includeRestrictedRegions` décide si elles sont incluses par défaut.
- En ligne de commande, `-IncludeChina` / `-ExcludeRestricted` priment sur la config.

## Modifier / ajouter des codes (quand tu veux)

### Option A — éditer directement le JSON

Ouvre `data/promo-codes.json` et ajoute un site ou un code. Format d'un code :

```json
{
  "code": "TECH10",
  "description": "10% sur l'électronique",
  "discount": "-10%",
  "validFrom": "2026-01-01",
  "validUntil": "2026-12-31",
  "minPurchase": 50,
  "categories": ["electronique"],
  "active": true
}
```

Un code n'est proposé que si `active` n'est pas `false` **et** que la date du jour est comprise entre `validFrom` et `validUntil` (dates au format `AAAA-MM-JJ`, inclusives, vides = pas de contrainte).

### Option B — via les fonctions du module (écriture sûre et atomique)

```powershell
Import-Module ./src/PromoAggregator.psd1

# Ajouter un site
Add-PromoSite -Id 'fnac' -Name 'Fnac' -Url 'https://www.fnac.com' -Countries FR -Categories electronique,livres

# Ajouter un code
Add-PromoCode -SiteId 'fnac' -Code 'NOEL15' -Discount '-15%' `
              -ValidFrom '2026-12-01' -ValidUntil '2026-12-31' -Categories electronique

# Désactiver / prolonger un code
Set-PromoCode -SiteId 'fnac' -Code 'NOEL15' -Active $false
Set-PromoCode -SiteId 'fnac' -Code 'NOEL15' -ValidUntil '2027-01-15'

# Supprimer un code
Remove-PromoCode -SiteId 'fnac' -Code 'NOEL15'
```

## Mise à jour automatique (tous les 3 jours)

Le catalogue peut se **rafraîchir automatiquement** pour récupérer de nouveaux codes.

1. Déclare tes **sources** dans `config/sources.json` (flux JSON en **HTTPS**, au même format que `data/promo-codes.json`). Mets `enabled: true` et l'URL :

   ```json
   {
     "sources": [
       { "id": "mon-flux", "url": "https://mon-domaine.com/promos.json", "enabled": true }
     ]
   }
   ```

2. La récupération + fusion tourne **tous les 3 jours** via GitHub Actions (`.github/workflows/update-promos.yml`) : nouveaux codes ajoutés, codes existants mis à jour, chaque code touché horodaté (`lastChecked`), puis commit automatique si changement.

3. Manuellement quand tu veux :

   ```bash
   pwsh ./Update-Promos.ps1          # respecte l'intervalle de 3 jours
   pwsh ./Update-Promos.ps1 -Force   # force tout de suite
   ```

La fusion (`Merge-PromoCatalog`) **dédoublonne** par identifiant de code (par site) et par titre d'offre : relancer la mise à jour ne crée pas de doublons. Les sources injoignables ou invalides sont ignorées sans bloquer les autres.

### Scraper des sites nommés (Amazon, etc.)

En plus des flux JSON, la mise à jour peut **scraper des sites que tu nommes**. Les sites sont décrits dans `config/scrapers.json` (**Amazon FR et US** y sont déjà). Chaque entrée :

```json
{
  "id": "amazon-fr",
  "name": "Amazon France",
  "url": "https://www.amazon.fr/promotions",
  "countries": ["FR"],
  "categories": ["general"],
  "codePattern": "(?i)code[^A-Za-z0-9]{0,15}(?<code>[A-Z0-9]{5,12})",
  "defaultValidityDays": 30,
  "maxCodes": 50,
  "enabled": true
}
```

- `codePattern` est une **regex** avec un groupe nommé obligatoire `(?<code>...)`, et des groupes optionnels `(?<description>...)` et `(?<discount>...)`.
- Les codes scrapés reçoivent une **validité glissante** (`validFrom` = aujourd'hui, `validUntil` = aujourd'hui + `defaultValidityDays`) : un code disparu de la page **expire de lui-même** à la mise à jour suivante.
- `maxCodes` plafonne le nombre de codes par site ; une liste blanche de format filtre le bruit.

**Ajouter un site en une commande :**

```powershell
Import-Module ./src/PromoAggregator.psd1
Add-PromoScraper -Id 'fnac' -Name 'Fnac' -Url 'https://www.fnac.com/promotions' `
    -Countries FR -CodePattern '(?i)code[^A-Za-z0-9]{0,15}(?<code>[A-Z0-9]{5,12})'
```

Puis `pwsh ./Update-Promos.ps1 -Force` (ou attends le cycle de 3 jours).

> ⚠️ **À savoir** : respecte les CGU et le `robots.txt` de chaque site. Les pages des grands sites sont souvent dynamiques (JavaScript) — `url` doit pointer vers une page qui contient réellement les codes en HTML, et `codePattern` doit être **ajusté à la structure de cette page** pour extraire de vrais codes. Le moteur est générique et sûr ; l'ajustement du motif est ce qui rend l'extraction efficace pour un site donné. Dis-moi le site et la page, je calibre le motif.

## Suivi de prix et alertes (PS5 Pro & Slim)

Les produits suivis sont décrits dans **`config/products.json`** (PS5 Pro et Slim, sur **Amazon, Fnac, Carrefour**). À chaque relevé, le prix est comparé au dernier prix connu (`data/price-history.json`) et **toute variation déclenche une alerte** — baisse comme hausse.

```jsonc
{
  "id": "ps5-pro",
  "name": "PlayStation 5 Pro",
  "alertThresholdPercent": 0,            // 0 = alerte à la moindre variation
  "sites": [
    { "site": "amazon-fr", "url": "https://www.amazon.fr/dp/...",
      "pricePattern": "\"price\"\\s*:\\s*\"?(?<price>[0-9]+(?:[.,][0-9]{2})?)", "enabled": true }
  ]
}
```

**Mise en route :**

1. Remplace chaque `url` `REMPLACER-...` par la **vraie page produit** (Amazon/Fnac/Carrefour) et vérifie le `pricePattern`.
2. Premier lancement pour enregistrer les prix de référence (sans alerte) :
   ```powershell
   pwsh ./Watch-Prices.ps1 -NoAlert
   ```
3. Ensuite, à chaque lancement, tu es alerté si le prix bouge :
   ```powershell
   pwsh ./Watch-Prices.ps1
   ```

**Comment tu es alerté (« directement ») :**

| Canal | Activation |
|-------|------------|
| Console (vert = baisse, rouge = hausse) | toujours |
| Fichier `data/alerts.json` | toujours |
| Webhook Discord/Slack | renseigne `alertWebhookUrl` (HTTPS) dans `config/settings.json`, ou la variable d'env `PROMO_ALERT_WEBHOOK` |
| Notification Windows (toast) | installe le module `BurntToast` (`Install-Module BurntToast`) |

**Automatisation :**
- En local (Windows) : planifie une tâche qui exécute `pwsh -File Watch-Prices.ps1` (ex. toutes les heures) via le Planificateur de tâches.
- Sur GitHub : `.github/workflows/watch-prices.yml` relève les prix **chaque jour** ; ajoute un secret de dépôt `PROMO_ALERT_WEBHOOK` pour recevoir les alertes.

### Tout en local, sans GitHub

Le projet n'a **pas besoin de GitHub** pour fonctionner : tout tourne sur ta machine.

1. **Récupère le code** sur ton PC (une fois) :
   ```powershell
   git clone -b claude/promo-code-aggregator-o81kf4 https://github.com/AAYKED/PERCUKU-Almir-Powershell1.git
   cd PERCUKU-Almir-Powershell1
   ```
   (ou télécharge le ZIP du dépôt et dézippe-le)

2. **Vérifie PowerShell 7** : `pwsh --version` (sinon `winget install Microsoft.PowerShell`).

3. **Initialise puis relève** :
   ```powershell
   pwsh ./Watch-Prices.ps1 -NoAlert   # 1re fois : enregistre les prix de référence
   pwsh ./Watch-Prices.ps1            # ensuite : alerte si un prix bouge
   ```

4. **Rends-le automatique** (Planificateur de tâches Windows, une seule commande) :
   ```powershell
   pwsh ./Register-PriceWatchTask.ps1 -IntervalHours 6 -RunNow   # relève toutes les 6 h
   pwsh ./Register-PriceWatchTask.ps1 -Unregister                # pour arrêter
   ```
   La tâche tourne en arrière-plan ; tu es alerté en console (si la fenêtre est ouverte), dans `data/alerts.json`, et par notification Windows si `BurntToast` est installé. Pour une alerte qui te suit partout, renseigne `alertWebhookUrl` (Discord/Slack) dans `config/settings.json`.

> Linux/macOS : `Register-PriceWatchTask.ps1` affiche la ligne `cron` équivalente à coller dans `crontab -e`.

> ⚠️ Les pages des grands sites sont souvent dynamiques (JavaScript) : pour extraire un prix fiable, `url` doit pointer vers une page qui contient le prix dans le HTML (la fiche produit fonctionne souvent via ses données structurées JSON-LD), et `pricePattern` doit correspondre. Donne-moi les URLs exactes des fiches PS5 et je calibre les motifs.

## Tests

```bash
# Sans dépendance (recommandé partout) :
pwsh ./tests/Invoke-Checks.ps1

# Avec Pester 5+ installé :
pwsh -c "Invoke-Pester ./tests/PromoAggregator.Tests.ps1"
```

## Sécurité (revue intégrée)

- `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`.
- **Aucune** évaluation dynamique (`Invoke-Expression`, `[scriptblock]::Create`, etc.).
- **Validation stricte** des entrées : codes pays (regex liste blanche), dates (`TryParseExact` en culture invariante), identifiants de site (unicité, non vides).
- **Validation du schéma** du catalogue à chaque chargement avant toute opération.
- **Écriture atomique** du catalogue (fichier temporaire + remplacement) en **UTF-8 sans BOM** (compatibilité des caractères chinois).
- Lectures de fichiers via `-LiteralPath` (pas d'interprétation de jokers).
- **Mise à jour réseau confinée** à `Update-PromoCatalog` / `Invoke-PromoScraper` : **HTTPS uniquement** (autres schémas refusés), redirections limitées, délai d'attente, et **données externes traitées comme non fiables** — validées par le schéma avant fusion. Aucune donnée distante n'est exécutée.
- **Scraping sûr** : le HTML est traité comme du **texte** (extraction par regex, jamais d'exécution), la regex a un **délai d'expiration** (anti-ReDoS), les codes sont filtrés par liste blanche de format et plafonnés (`maxCodes`). Une page injoignable ou bloquée n'ajoute **aucun** code et n'interrompt pas la mise à jour.
- **Prix/alertes** : relevé via HTTPS uniquement, extraction par regex à délai d'expiration, webhook d'alerte **HTTPS uniquement**. Une page sans prix ou injoignable est ignorée sans interrompre le suivi ; le webhook et la notification toast sont best-effort (une panne n'arrête rien).
