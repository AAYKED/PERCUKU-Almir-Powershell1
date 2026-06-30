#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Verificateur sans dependance pour PromoAggregator (alternative a Pester).
.DESCRIPTION
    Execute une serie d'assertions sur un catalogue de test isole, sans modifier
    data/promo-codes.json. Code de sortie 0 si tout passe, 1 sinon. Utilisable dans
    un environnement ou Pester n'est pas installable.
.EXAMPLE
    pwsh ./tests/Invoke-Checks.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Root 'src/PromoAggregator.psd1') -Force

$script:Pass = 0
$script:Fail = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        $ok = & $Test
        if ($ok) { $script:Pass++; Write-Host "  [OK]   $Name" -ForegroundColor Green }
        else     { $script:Fail++; Write-Host "  [FAIL] $Name" -ForegroundColor Red }
    } catch {
        $script:Fail++
        Write-Host "  [FAIL] $Name -> $($_.Exception.Message)" -ForegroundColor Red
    }
}

function CheckThrows([string]$Name, [scriptblock]$Test) {
    try { & $Test; $script:Fail++; Write-Host "  [FAIL] $Name (aucune exception)" -ForegroundColor Red }
    catch { $script:Pass++; Write-Host "  [OK]   $Name" -ForegroundColor Green }
}

# --- Catalogue de test isole -------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("promo-checks-{0}.json" -f ([guid]::NewGuid()))
$fixture = @{
    schemaVersion = '1.0'
    sites = @(
        @{
            id = 'shop-fr'; name = 'Shop FR'; url = 'https://shop.fr'
            countries = @('FR'); categories = @('electronique')
            codes = @(
                @{ code = 'OK10'; description = 'valide'; discount = '-10%'; validFrom = '2026-01-01'; validUntil = '2026-12-31'; minPurchase = 0; categories = @('electronique'); active = $true },
                @{ code = 'OLD';  description = 'expire'; discount = '-50%'; validFrom = '2025-01-01'; validUntil = '2025-12-31'; minPurchase = 0; categories = @(); active = $true },
                @{ code = 'OFF';  description = 'desactive'; discount = '-5%'; validFrom = '2026-01-01'; validUntil = '2026-12-31'; minPurchase = 0; categories = @(); active = $false }
            )
            offers = @(@{ title = 'Soldes'; description = 'promo'; url = 'https://shop.fr/soldes'; validUntil = '2026-12-31' })
        },
        @{
            id = 'shop-cn'; name = 'Shop CN'; url = 'https://shop.cn'
            countries = @('CN'); categories = @('mode')
            codes = @()
            offers = @(@{ title = '11.11'; description = 'singles day'; url = 'https://shop.cn'; validUntil = '2026-11-12' })
        }
    )
}
($fixture | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $tmp -Encoding utf8

try {
    $catalog = Get-PromoCatalog -Path $tmp
    $ref = [datetime]'2026-06-30'
    $siteFr = $catalog.sites | Where-Object id -eq 'shop-fr'
    $siteCn = $catalog.sites | Where-Object id -eq 'shop-cn'

    Write-Host "`nValidation des codes pays" -ForegroundColor Cyan
    Check 'ALL accepte'        { Test-CountryCode 'ALL' }
    Check 'FR accepte'         { Test-CountryCode 'FR' }
    Check 'FRA rejete'         { -not (Test-CountryCode 'FRA') }
    Check 'vide rejete'        { -not (Test-CountryCode '') }

    Write-Host "`nParsing des dates" -ForegroundColor Cyan
    Check 'date ISO valide'    { (ConvertTo-PromoDate '2026-06-30') -eq ([datetime]'2026-06-30') }
    Check 'date vide -> null'  { $null -eq (ConvertTo-PromoDate '') }
    CheckThrows 'date invalide leve' { ConvertTo-PromoDate '30/06/2026' }

    Write-Host "`nValidite des codes promo" -ForegroundColor Cyan
    Check 'code en fenetre valide'  { Test-PromoCodeActive -Code ($siteFr.codes | Where-Object code -eq 'OK10') -ReferenceDate $ref }
    Check 'code expire rejete'      { -not (Test-PromoCodeActive -Code ($siteFr.codes | Where-Object code -eq 'OLD') -ReferenceDate $ref) }
    Check 'code desactive rejete'   { -not (Test-PromoCodeActive -Code ($siteFr.codes | Where-Object code -eq 'OFF') -ReferenceDate $ref) }

    Write-Host "`nFiltrage pays / Chine" -ForegroundColor Cyan
    Check 'ALL -> Chine incluse'    { Test-SiteMatchesCountry -Site $siteCn -Country 'ALL' }
    Check 'FR exact'                { Test-SiteMatchesCountry -Site $siteFr -Country 'FR' }
    Check 'US sans restreint exclut FR' { -not (Test-SiteMatchesCountry -Site $siteFr -Country 'US' -IncludeRestrictedRegions $false) }
    Check 'Chine incluse via switch' { Test-SiteMatchesCountry -Site $siteCn -Country 'FR' -IncludeRestrictedRegions $true }
    Check 'Chine exclue via switch'  { -not (Test-SiteMatchesCountry -Site $siteCn -Country 'FR' -IncludeRestrictedRegions $false) }

    Write-Host "`nRecherche (Find-PromoCode)" -ForegroundColor Cyan
    Check 'ne renvoie que codes valides' {
        $fr = Find-PromoCode -Country 'FR' -Catalog $catalog -ReferenceDate $ref | Where-Object SiteId -eq 'shop-fr'
        (@($fr.ValidCodes).Count -eq 1) -and ($fr.ValidCodes[0].code -eq 'OK10')
    }
    Check 'offres si aucun code valide' {
        $cn = Find-PromoCode -Country 'CN' -Catalog $catalog -ReferenceDate $ref | Where-Object SiteId -eq 'shop-cn'
        (-not $cn.HasValidCode) -and (@($cn.BestOffers).Count -gt 0)
    }
    Check 'filtre categorie mode' {
        $res = Find-PromoCode -Category 'mode' -Worldwide -Catalog $catalog -ReferenceDate $ref
        (-not ($res | Where-Object SiteId -eq 'shop-fr')) -and ($res | Where-Object SiteId -eq 'shop-cn')
    }
    CheckThrows 'pays invalide leve' { Find-PromoCode -Country 'XXX' -Catalog $catalog }

    Write-Host "`nGestion du catalogue (ecriture atomique)" -ForegroundColor Cyan
    Check 'ajout code' {
        Add-PromoCode -SiteId 'shop-fr' -Code 'NEW20' -Discount '-20%' -ValidFrom '2026-01-01' -ValidUntil '2026-12-31' -Path $tmp | Out-Null
        $c = Get-PromoCatalog -Path $tmp
        $null -ne (($c.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'NEW20')
    }
    Check 'modification code (active=false)' {
        Set-PromoCode -SiteId 'shop-fr' -Code 'NEW20' -Active $false -Path $tmp | Out-Null
        $c = Get-PromoCatalog -Path $tmp
        (($c.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'NEW20').active -eq $false
    }
    Check 'suppression code' {
        Remove-PromoCode -SiteId 'shop-fr' -Code 'NEW20' -Path $tmp
        $c = Get-PromoCatalog -Path $tmp
        $null -eq (($c.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'NEW20')
    }
    CheckThrows 'doublon refuse'        { Add-PromoCode -SiteId 'shop-fr' -Code 'OK10' -Path $tmp }
    CheckThrows 'site inconnu refuse'   { Add-PromoCode -SiteId 'inconnu' -Code 'ZZZ' -Path $tmp }

    Write-Host "`nMise a jour : fusion des sources (Merge-PromoCatalog)" -ForegroundColor Cyan
    Check 'ajoute un nouveau code avec lastChecked' {
        $cat = Get-PromoCatalog -Path $tmp
        $source = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-fr'; name = 'Shop FR'; countries = @('FR'); codes = @(@{ code = 'FRESH'; discount = '-30%'; validFrom = '2026-01-01'; validUntil = '2026-12-31'; active = $true }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $r = Merge-PromoCatalog -Catalog $cat -Source $source -Today ([datetime]'2026-06-30')
        $new = ($cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'FRESH'
        ($r.Added -ge 1) -and ($null -ne $new) -and ($new.lastChecked -eq '2026-06-30')
    }
    Check 'met a jour un code existant' {
        $cat = Get-PromoCatalog -Path $tmp
        $source = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-fr'; name = 'Shop FR'; countries = @('FR'); codes = @(@{ code = 'OK10'; discount = '-99%'; validFrom = '2026-01-01'; validUntil = '2027-01-01'; active = $true }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $r = Merge-PromoCatalog -Catalog $cat -Source $source -Today ([datetime]'2026-06-30')
        $upd = ($cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'OK10'
        ($r.Updated -ge 1) -and ($upd.discount -eq '-99%') -and ($upd.validUntil -eq '2027-01-01')
    }
    Check 'ajoute un nouveau site' {
        $cat = Get-PromoCatalog -Path $tmp
        $source = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-us'; name = 'Shop US'; countries = @('US'); codes = @(@{ code = 'USA5'; discount = '-5%'; active = $true }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Merge-PromoCatalog -Catalog $cat -Source $source -Today ([datetime]'2026-06-30') | Out-Null
        $null -ne ($cat.sites | Where-Object id -eq 'shop-us')
    }
    Check 'ne duplique pas une offre existante' {
        $cat = Get-PromoCatalog -Path $tmp
        $before = @(($cat.sites | Where-Object id -eq 'shop-fr').offers).Count
        $source = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-fr'; name = 'Shop FR'; countries = @('FR'); offers = @(@{ title = 'Soldes'; description = 'doublon' }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Merge-PromoCatalog -Catalog $cat -Source $source -Today ([datetime]'2026-06-30') | Out-Null
        @(($cat.sites | Where-Object id -eq 'shop-fr').offers).Count -eq $before
    }
    Check 'sources HTTPS only (config exemple)' {
        $sources = Get-PromoSources -Path (Join-Path $Root 'config/sources.json')
        # La source d'exemple est desactivee : aucune source active par defaut.
        @($sources | Where-Object { $_.enabled }).Count -eq 0
    }

    Write-Host "`nScraping de sites nommes (ConvertFrom-ScrapedHtml)" -ForegroundColor Cyan
    $scraper = [pscustomobject]@{
        id = 'test-shop'; name = 'Test Shop'; url = 'https://test.example'
        countries = @('FR'); categories = @('general')
        codePattern = '(?i)code[^A-Za-z0-9]{0,5}(?<code>[A-Z0-9]{4,12})'
        defaultValidityDays = 15; maxCodes = 10
    }
    $html = 'Promo CODE: SUMMER20 ... autre CODE WELCOME10 ... doublon CODE: SUMMER20 ... bruit CODE: AB'
    Check 'extrait les codes valides et dedoublonne' {
        $site = ConvertFrom-ScrapedHtml -Html $html -Scraper $scraper -Today ([datetime]'2026-06-30')
        $codes = @($site.codes.code)
        (@($site.codes).Count -eq 2) -and ($codes -contains 'SUMMER20') -and ($codes -contains 'WELCOME10')
    }
    Check 'applique la validite glissante' {
        $site = ConvertFrom-ScrapedHtml -Html $html -Scraper $scraper -Today ([datetime]'2026-06-30')
        $c = $site.codes | Select-Object -First 1
        ($c.validFrom -eq '2026-06-30') -and ($c.validUntil -eq '2026-07-15') -and ($c.source -eq 'scrape')
    }
    Check 'HTML vide -> aucun code, site valide' {
        $site = ConvertFrom-ScrapedHtml -Html '' -Scraper $scraper -Today ([datetime]'2026-06-30')
        (@($site.codes).Count -eq 0) -and ($site.id -eq 'test-shop')
    }
    Check 'respecte maxCodes' {
        $sc2 = $scraper.PSObject.Copy(); $sc2.maxCodes = 1
        $site = ConvertFrom-ScrapedHtml -Html $html -Scraper $sc2 -Today ([datetime]'2026-06-30')
        @($site.codes).Count -eq 1
    }
    Check 'le resultat scrape est fusionnable' {
        $cat = Get-PromoCatalog -Path $tmp
        $site = ConvertFrom-ScrapedHtml -Html $html -Scraper $scraper -Today ([datetime]'2026-06-30')
        $wrapped = [pscustomobject]@{ schemaVersion = '1.0'; sites = @($site) }
        $r = Merge-PromoCatalog -Catalog $cat -Source $wrapped -Today ([datetime]'2026-06-30')
        ($r.Added -ge 2) -and ($null -ne ($cat.sites | Where-Object id -eq 'test-shop'))
    }
    CheckThrows 'scraper sans codePattern leve' {
        $bad = [pscustomobject]@{ id = 'x'; name = 'X'; countries = @('FR') }
        ConvertFrom-ScrapedHtml -Html $html -Scraper $bad
    }
    Check 'config/scrapers.json valide et Amazon present' {
        $defs = Get-PromoScrapers -Path (Join-Path $Root 'config/scrapers.json')
        @($defs | Where-Object { $_.id -like 'amazon*' }).Count -ge 1
    }

    Write-Host "`nPrix : normalisation (ConvertTo-Price)" -ForegroundColor Cyan
    Check "'599,99 EUR' -> 599.99"   { (ConvertTo-Price '599,99 EUR') -eq [decimal]599.99 }
    Check "'1 199,99' -> 1199.99"    { (ConvertTo-Price '1 199,99') -eq [decimal]1199.99 }
    Check '"$1,299.00" -> 1299.00'   { (ConvertTo-Price '$1,299.00') -eq [decimal]1299.00 }
    Check "'1.299,00' -> 1299.00"    { (ConvertTo-Price '1.299,00') -eq [decimal]1299.00 }
    Check "'799' -> 799"             { (ConvertTo-Price '799') -eq [decimal]799 }
    Check "vide -> null"             { $null -eq (ConvertTo-Price '') }

    Write-Host "`nPrix : extraction HTML (ConvertFrom-ScrapedPrice)" -ForegroundColor Cyan
    Check 'extrait depuis JSON-LD' {
        (ConvertFrom-ScrapedPrice -Html '...{"@type":"Offer","price":"799.99","priceCurrency":"EUR"}...' -Pattern '"price"\s*:\s*"?(?<price>[0-9]+(?:[.,][0-9]{2})?)') -eq [decimal]799.99
    }
    Check 'extrait un prix en euros texte' {
        (ConvertFrom-ScrapedPrice -Html '<span>Prix : 699,00 EUR</span>' -Pattern '(?<price>[0-9][0-9 .,]*)\s*EUR') -eq [decimal]699.00
    }
    Check 'aucun match -> null' {
        $null -eq (ConvertFrom-ScrapedPrice -Html 'pas de prix ici' -Pattern '"price"\s*:\s*"?(?<price>[0-9.]+)')
    }

    Write-Host "`nPrix : detection de variation (Compare-PriceChange)" -ForegroundColor Cyan
    Check 'baisse detectee' {
        $c = Compare-PriceChange -OldPrice ([decimal]799.99) -NewPrice ([decimal]699.99)
        $c.Changed -and ($c.Direction -eq 'baisse') -and ($c.Percent -lt 0)
    }
    Check 'hausse detectee' {
        $c = Compare-PriceChange -OldPrice ([decimal]699.99) -NewPrice ([decimal]749.99)
        $c.Changed -and ($c.Direction -eq 'hausse') -and ($c.Percent -gt 0)
    }
    Check 'stable -> pas de changement' {
        -not (Compare-PriceChange -OldPrice ([decimal]799) -NewPrice ([decimal]799)).Changed
    }
    Check 'premier releve -> nouveau, pas d''alerte' {
        $c = Compare-PriceChange -OldPrice $null -NewPrice ([decimal]799)
        (-not $c.Changed) -and ($c.Direction -eq 'nouveau')
    }
    Check 'seuil respecte (1% < 2% seuil)' {
        -not (Compare-PriceChange -OldPrice ([decimal]100) -NewPrice ([decimal]101) -ThresholdPercent 2).Changed
    }

    Write-Host "`nPrix : configuration produits et historique" -ForegroundColor Cyan
    Check 'config/products.json valide (PS5 Pro + Slim)' {
        $prods = Get-PromoProducts -Path (Join-Path $Root 'config/products.json')
        $ids = @($prods.products.id)
        ($ids -contains 'ps5-pro') -and ($ids -contains 'ps5-slim')
    }
    Check 'PS5 suivie sur amazon, fnac et carrefour' {
        $prods = Get-PromoProducts -Path (Join-Path $Root 'config/products.json')
        $sites = @(($prods.products | Where-Object id -eq 'ps5-pro').sites.site)
        ($sites -contains 'amazon-fr') -and ($sites -contains 'fnac') -and ($sites -contains 'carrefour')
    }
    Check 'historique des prix chargeable' {
        $h = Get-PriceHistory -Path (Join-Path $Root 'data/price-history.json')
        $h.PSObject.Properties.Name -contains 'entries'
    }

    Write-Host "`nValidation du catalogue livre (data/promo-codes.json)" -ForegroundColor Cyan
    Check 'catalogue principal valide'  { $null -ne (Get-PromoCatalog) }
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
}

Write-Host ("`nResultat : {0} reussis, {1} echecs." -f $script:Pass, $script:Fail) -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
Write-Host "Tous les controles sont passes." -ForegroundColor Green
exit 0
