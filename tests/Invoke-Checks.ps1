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
