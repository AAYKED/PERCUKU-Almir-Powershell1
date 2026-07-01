#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    PromoAggregator - interface en ligne de commande.

.DESCRIPTION
    Recherche les codes promo VALIDES des sites du catalogue, filtre par pays
    (monde entier, pays precis, ou regions a acces restreint comme la Chine), et
    propose les meilleures offres quand un site n'a aucun code valide. Sans
    parametre, lance un mode interactif qui questionne sur l'article recherche.

.PARAMETER Query
    Mot-cle libre : nom de site, identifiant ou partie d'URL.

.PARAMETER Category
    Categorie d'article (ex: electronique, mode, livres, maison).

.PARAMETER Country
    Filtre pays : 'ALL' (monde entier) ou code ISO 2 lettres (FR, CN, US, ...).

.PARAMETER Worldwide
    Force la recherche mondiale (equivaut a -Country ALL).

.PARAMETER IncludeChina
    Inclut explicitement la Chine et les autres regions a acces restreint.

.PARAMETER ExcludeRestricted
    Exclut la Chine et les autres regions a acces restreint.

.PARAMETER List
    Liste tous les sites du catalogue avec leur nombre de codes valides.

.PARAMETER Interactive
    Force le mode interactif (questions guidees).

.EXAMPLE
    ./promo.ps1 -Query amazon -Country FR

.EXAMPLE
    ./promo.ps1 -Category electronique -Worldwide -IncludeChina

.EXAMPLE
    ./promo.ps1            # mode interactif
#>
[CmdletBinding(DefaultParameterSetName = 'Search')]
param(
    [Parameter(ParameterSetName = 'Search')][string]$Query,
    [Parameter(ParameterSetName = 'Search')][string]$Category,
    [Parameter(ParameterSetName = 'Search')][string]$Country,
    [Parameter(ParameterSetName = 'Search')][switch]$Worldwide,
    [Parameter(ParameterSetName = 'Search')][switch]$IncludeChina,
    [Parameter(ParameterSetName = 'Search')][switch]$ExcludeRestricted,
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Interactive')][switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/PromoAggregator.psd1') -Force

# ---------------------------------------------------------------------------
# Affichage
# ---------------------------------------------------------------------------

function Write-Heading([string]$Text) {
    Write-Host ''
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Show-SiteResult($Result) {
    Write-Host ''
    Write-Host ("-> {0}  [{1}]" -f $Result.SiteName, ($Result.Countries -join ', ')) -ForegroundColor Yellow
    if ($Result.Url) { Write-Host ("   {0}" -f $Result.Url) -ForegroundColor DarkGray }

    if ($Result.HasValidCode) {
        Write-Host "   Codes promo valides :" -ForegroundColor Green
        foreach ($c in $Result.ValidCodes) {
            $min = if ($c.PSObject.Properties.Name -contains 'minPurchase' -and $c.minPurchase) { " (des $($c.minPurchase))" } else { '' }
            $until = if ($c.PSObject.Properties.Name -contains 'validUntil' -and $c.validUntil) { " - jusqu'au $($c.validUntil)" } else { '' }
            Write-Host ("     * {0}  {1}  {2}{3}{4}" -f $c.code, $c.discount, $c.description, $min, $until)
        }
    } else {
        Write-Host "   Aucun code promo valide pour ce site." -ForegroundColor DarkYellow
    }

    if (@($Result.BestOffers).Count -gt 0) {
        $label = if ($Result.HasValidCode) { 'Autres offres :' } else { 'Meilleures offres du moment :' }
        Write-Host "   $label" -ForegroundColor Magenta
        foreach ($o in $Result.BestOffers) {
            $until = if ($o.PSObject.Properties.Name -contains 'validUntil' -and $o.validUntil) { " (jusqu'au $($o.validUntil))" } else { '' }
            Write-Host ("     - {0}{1}" -f $o.title, $until)
            if ($o.PSObject.Properties.Name -contains 'description' -and $o.description) {
                Write-Host ("       {0}" -f $o.description) -ForegroundColor DarkGray
            }
        }
    }
}

function Show-Results($Results, [string]$Country) {
    $Results = @($Results | Where-Object { $null -ne $_ })
    Write-Heading "Resultats (filtre pays : $Country)"
    if (@($Results).Count -eq 0) {
        Write-Host "Aucun site ne correspond a ces criteres. Essaie d'elargir le pays (-Worldwide) ou de retirer la categorie." -ForegroundColor Red
        return
    }
    $withCode = @($Results | Where-Object { $_.HasValidCode })
    foreach ($r in $Results) { Show-SiteResult -Result $r }
    Write-Host ''
    Write-Host ("Bilan : {0} site(s) trouve(s), dont {1} avec au moins un code promo valide." -f @($Results).Count, $withCode.Count) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Mode liste
# ---------------------------------------------------------------------------

function Invoke-ListMode {
    $catalog = Get-PromoCatalog
    $today = (Get-Date).Date
    Write-Heading 'Catalogue des sites'
    foreach ($site in @($catalog.sites)) {
        $codes = if ($site.PSObject.Properties.Name -contains 'codes' -and $null -ne $site.codes) { @($site.codes) } else { @() }
        $validCount = @($codes | Where-Object { Test-PromoCodeActive -Code $_ -ReferenceDate $today }).Count
        Write-Host ("- {0,-22} [{1,-12}] codes valides: {2}" -f $site.name, ($site.countries -join ','), $validCount)
    }
    Write-Host ''
    Write-Host "Pour modifier le catalogue : edite data/promo-codes.json, ou utilise Add-PromoCode / Set-PromoCode / Remove-PromoCode." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Mode interactif
# ---------------------------------------------------------------------------

function Read-Default([string]$Prompt, [string]$Default) {
    $answer = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Invoke-InteractiveMode {
    Write-Heading 'Recherche de codes promo - mode interactif'
    Write-Host "Reponds aux questions (Entree = valeur par defaut)." -ForegroundColor DarkGray

    $article = Read-Host 'Que recherches-tu ? (article, marque ou site, ex: casque, amazon)'
    $category = Read-Default 'Categorie ? (electronique, mode, livres, maison... ou vide)' ''
    $country = Read-Default "Pays ? (ALL = monde entier, ou code ISO comme FR, CN, US)" 'ALL'

    $chinaAns = Read-Default 'Inclure la Chine et les regions a acces restreint ? (O/N)' 'O'
    $includeChina = $chinaAns -match '^(o|oui|y|yes)$'

    $params = @{ Country = $country; IncludeRestrictedRegions = [bool]$includeChina }
    if (-not [string]::IsNullOrWhiteSpace($article))  { $params.Query = $article }
    if (-not [string]::IsNullOrWhiteSpace($category)) { $params.Category = $category }

    $results = @(Find-PromoCode @params)
    Show-Results -Results $results -Country $country

    # Questionnement complementaire : si rien avec code, on aide a affiner sur l'article.
    if (@($results | Where-Object { $_.HasValidCode }).Count -eq 0) {
        Write-Host ''
        Write-Host "Aucun code promo valide trouve pour cette recherche." -ForegroundColor DarkYellow
        Write-Host "Les meilleures offres ci-dessus restent disponibles. Tu peux preciser ta recherche :" -ForegroundColor DarkYellow
        $refine = Read-Default 'Veux-tu elargir au monde entier (toutes regions) ? (O/N)' 'O'
        if ($refine -match '^(o|oui|y|yes)$') {
            $results = @(Find-PromoCode -Worldwide -IncludeRestrictedRegions $true `
                    -Query $params.Query -Category $params.Category)
            Show-Results -Results $results -Country 'ALL'
        }
    }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

try {
    switch ($PSCmdlet.ParameterSetName) {
        'List' { Invoke-ListMode; break }
        'Interactive' { Invoke-InteractiveMode; break }
        default {
            $noArgs = -not ($PSBoundParameters.Keys | Where-Object { $_ -in 'Query', 'Category', 'Country', 'Worldwide', 'IncludeChina', 'ExcludeRestricted' })
            if ($noArgs) {
                Invoke-InteractiveMode
            } else {
                if (-not $Country) { $Country = 'ALL' }
                $includeRestricted = $null
                if ($IncludeChina)      { $includeRestricted = $true }
                if ($ExcludeRestricted) { $includeRestricted = $false }

                $params = @{ Query = $Query; Category = $Category; Country = $Country; Worldwide = $Worldwide }
                if ($null -ne $includeRestricted) { $params.IncludeRestrictedRegions = $includeRestricted }
                $results = @(Find-PromoCode @params)
                Show-Results -Results $results -Country $(if ($Worldwide) { 'ALL' } else { $Country })
            }
        }
    }
} catch {
    Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
