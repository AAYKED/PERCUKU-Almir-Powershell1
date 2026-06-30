# PromoAggregator

Agrégateur de **codes promo multi-sites** en PowerShell. Il ne propose **que des codes valides**, filtre par **pays** (monde entier, pays précis, ou régions à accès restreint comme la **Chine**), et affiche les **meilleures offres** lorsqu'un site n'a aucun code promo valide. Le catalogue est un simple fichier JSON **que tu modifies et enrichis quand tu veux**.

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
config/scrapers.json            Sites à scraper par nom (Amazon, etc.)
Update-Promos.ps1               Mise à jour manuelle/planifiée (récup + fusion)
.github/workflows/              Planification cron tous les 3 jours
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
