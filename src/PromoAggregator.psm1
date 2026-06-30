#Requires -Version 7.0
<#
.SYNOPSIS
    PromoAggregator - Agregateur de codes promo multi-sites, oriente donnees et securise.

.DESCRIPTION
    Ce module lit un catalogue editable (data/promo-codes.json), ne renvoie que les
    codes promo VALIDES (actifs et dans leur fenetre de validite), filtre par pays
    (monde entier, pays precis, ou regions a acces restreint comme la Chine), et
    propose les meilleures offres lorsqu'un site n'a aucun code promo valide.

    Principes de securite appliques :
      - Set-StrictMode + $ErrorActionPreference = 'Stop'
      - Aucune utilisation de Invoke-Expression ni d'evaluation dynamique
      - Validation stricte du schema des donnees a chaque chargement
      - Validation des entrees (codes pays, identifiants) par liste blanche / regex
      - Parsing des dates en culture invariante (pas d'ambiguite locale)
      - Ecriture atomique du catalogue (fichier temporaire + remplacement) en UTF-8
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Chemin de base = racine du projet (dossier parent du dossier src)
$script:ModuleRoot  = Split-Path -Parent $PSScriptRoot
$script:ConfigPath  = Join-Path $script:ModuleRoot 'config/settings.json'

# ---------------------------------------------------------------------------
# Helpers internes
# ---------------------------------------------------------------------------

# Validation d'un code pays ISO (2 lettres) ou du mot-cle 'ALL'.
function Test-CountryCode {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Country)
    return $Country -match '^(ALL|[A-Za-z]{2})$'
}

# Parse une date AAAA-MM-JJ en culture invariante. Retourne $null si invalide/absente.
function ConvertTo-PromoDate {
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Value, 'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed)
    if (-not $ok) { throw "Date invalide '$Value'. Format attendu : AAAA-MM-JJ." }
    return $parsed.Date
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-PromoConfig {
    <#
    .SYNOPSIS Charge les reglages (config/settings.json) avec valeurs par defaut sures.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path = $script:ConfigPath)

    $defaults = [pscustomobject]@{
        defaultCountry           = 'ALL'
        includeRestrictedRegions = $true
        restrictedRegions        = @('CN', 'RU', 'IR', 'KP')
        catalogPath              = 'data/promo-codes.json'
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose "Aucun fichier de config a '$Path' : utilisation des valeurs par defaut."
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $cfg = $raw | ConvertFrom-Json -Depth 10
    } catch {
        throw "Impossible de lire la configuration '$Path' : $($_.Exception.Message)"
    }

    # Fusion avec les valeurs par defaut (robustesse si une cle manque).
    foreach ($prop in $defaults.PSObject.Properties) {
        $hasValue = $cfg.PSObject.Properties.Name -contains $prop.Name -and $null -ne $cfg.$($prop.Name)
        if (-not $hasValue) {
            $cfg | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }
    return $cfg
}

function Get-PromoCatalogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([pscustomobject]$Config = (Get-PromoConfig))

    $catalog = $Config.catalogPath
    if ([System.IO.Path]::IsPathRooted($catalog)) { return $catalog }
    return Join-Path $script:ModuleRoot $catalog
}

# ---------------------------------------------------------------------------
# Catalogue : chargement, validation, sauvegarde
# ---------------------------------------------------------------------------

function Assert-CatalogSchema {
    <#
    .SYNOPSIS Valide la structure du catalogue. Leve une exception explicite si invalide.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)

    if ($null -eq $Catalog) { throw 'Catalogue vide ou illisible.' }
    if (-not ($Catalog.PSObject.Properties.Name -contains 'sites')) {
        throw "Catalogue invalide : propriete 'sites' manquante."
    }
    if ($null -eq $Catalog.sites) { return } # catalogue vide autorise

    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($site in @($Catalog.sites)) {
        foreach ($req in 'id', 'name', 'countries') {
            if (-not ($site.PSObject.Properties.Name -contains $req)) {
                throw "Site invalide : champ obligatoire '$req' manquant."
            }
        }
        if ([string]::IsNullOrWhiteSpace($site.id)) { throw "Un site possede un 'id' vide." }
        if (-not $seenIds.Add([string]$site.id)) {
            throw "Identifiant de site duplique : '$($site.id)'. Les id doivent etre uniques."
        }
        foreach ($c in @($site.countries)) {
            if (-not (Test-CountryCode -Country ([string]$c))) {
                throw "Site '$($site.id)' : code pays invalide '$c' (attendu : 2 lettres ou 'ALL')."
            }
        }
        # Validation des dates des codes (leve si format incorrect).
        if ($site.PSObject.Properties.Name -contains 'codes' -and $null -ne $site.codes) {
            foreach ($code in @($site.codes)) {
                if (-not ($code.PSObject.Properties.Name -contains 'code') -or `
                        [string]::IsNullOrWhiteSpace($code.code)) {
                    throw "Site '$($site.id)' : un code promo a un champ 'code' vide."
                }
                if ($code.PSObject.Properties.Name -contains 'validFrom')  { [void](ConvertTo-PromoDate $code.validFrom) }
                if ($code.PSObject.Properties.Name -contains 'validUntil') { [void](ConvertTo-PromoDate $code.validUntil) }
            }
        }
    }
}

function Get-PromoCatalog {
    <#
    .SYNOPSIS Charge et valide le catalogue de codes promo.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)

    if (-not $Path) { $Path = Get-PromoCatalogPath }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Catalogue introuvable : '$Path'."
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $catalog = $raw | ConvertFrom-Json -Depth 20
    } catch {
        throw "Catalogue illisible '$Path' : $($_.Exception.Message)"
    }

    Assert-CatalogSchema -Catalog $catalog
    return $catalog
}

function Save-PromoCatalog {
    <#
    .SYNOPSIS Sauvegarde le catalogue de maniere atomique (UTF-8, valide avant ecriture).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$Path
    )

    if (-not $Path) { $Path = Get-PromoCatalogPath }
    Assert-CatalogSchema -Catalog $Catalog

    if ($PSCmdlet.ShouldProcess($Path, 'Ecrire le catalogue')) {
        $json = $Catalog | ConvertTo-Json -Depth 20
        $tmp  = "$Path.tmp"
        # UTF-8 sans BOM pour la compatibilite maximale (caracteres chinois inclus).
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}

# ---------------------------------------------------------------------------
# Validite des codes
# ---------------------------------------------------------------------------

function Test-PromoCodeActive {
    <#
    .SYNOPSIS Determine si un code promo est valide a une date de reference donnee.
    .DESCRIPTION
        Valide si : active != false ET (pas de validFrom OU validFrom <= reference)
        ET (pas de validUntil OU reference <= validUntil).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Code,
        [datetime]$ReferenceDate = (Get-Date).Date
    )

    $ref = $ReferenceDate.Date

    # 'active' absent => considere actif ; seul active=false desactive.
    if ($Code.PSObject.Properties.Name -contains 'active' -and $Code.active -eq $false) {
        return $false
    }

    $from  = if ($Code.PSObject.Properties.Name -contains 'validFrom')  { ConvertTo-PromoDate $Code.validFrom }  else { $null }
    $until = if ($Code.PSObject.Properties.Name -contains 'validUntil') { ConvertTo-PromoDate $Code.validUntil } else { $null }

    if ($null -ne $from  -and $ref -lt $from)  { return $false }
    if ($null -ne $until -and $ref -gt $until) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Filtrage pays / region
# ---------------------------------------------------------------------------

function Test-SiteMatchesCountry {
    <#
    .SYNOPSIS Indique si un site doit etre propose pour le filtre pays demande.
    .DESCRIPTION
        - Country = 'ALL'  -> tous les sites (monde entier).
        - Sinon, le site correspond s'il dessert le pays demande, ou s'il est mondial ('ALL').
        - IncludeRestrictedRegions = $true autorise en plus les sites des regions a acces
          restreint (ex: Chine) meme quand un pays different est demande, via le commutateur.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Site,
        [string]$Country = 'ALL',
        [bool]$IncludeRestrictedRegions = $true,
        [string[]]$RestrictedRegions = @('CN', 'RU', 'IR', 'KP')
    )

    $siteCountries = @($Site.countries | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $country = $Country.ToUpperInvariant()

    if ($country -eq 'ALL') { return $true }
    if ($siteCountries -contains 'ALL') { return $true }
    if ($siteCountries -contains $country) { return $true }

    if ($IncludeRestrictedRegions) {
        foreach ($sc in $siteCountries) {
            if ($RestrictedRegions -contains $sc) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Recherche principale
# ---------------------------------------------------------------------------

function Find-PromoCode {
    <#
    .SYNOPSIS Recherche les codes promo valides selon des criteres, sinon propose les meilleures offres.
    .PARAMETER Query Mot-cle libre (nom de site, partie d'URL ou d'identifiant).
    .PARAMETER Category Categorie d'article recherchee (ex: electronique, mode, livres).
    .PARAMETER Country Filtre pays : 'ALL' (monde entier), ou code ISO (ex: FR, CN, US).
    .PARAMETER Worldwide Force le filtre 'ALL' (ignore le pays).
    .PARAMETER IncludeRestrictedRegions Autorise les regions a acces restreint (ex: Chine).
    .OUTPUTS Un objet par site contenant ses codes valides et/ou ses meilleures offres.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Query,
        [string]$Category,
        [string]$Country,
        [switch]$Worldwide,
        [Nullable[bool]]$IncludeRestrictedRegions,
        [datetime]$ReferenceDate = (Get-Date).Date,
        [pscustomobject]$Catalog,
        [pscustomobject]$Config
    )

    if (-not $Config)  { $Config  = Get-PromoConfig }
    if (-not $Catalog) { $Catalog = Get-PromoCatalog -Path (Get-PromoCatalogPath -Config $Config) }

    if ($Worldwide) { $Country = 'ALL' }
    if (-not $Country) { $Country = [string]$Config.defaultCountry }
    if ([string]::IsNullOrWhiteSpace($Country)) { $Country = 'ALL' }
    if (-not (Test-CountryCode -Country $Country)) {
        throw "Filtre pays invalide '$Country' (attendu : code ISO 2 lettres ou 'ALL')."
    }

    $includeRestricted = if ($null -ne $IncludeRestrictedRegions) {
        [bool]$IncludeRestrictedRegions
    } else {
        [bool]$Config.includeRestrictedRegions
    }
    $restricted = @($Config.restrictedRegions | ForEach-Object { ([string]$_).ToUpperInvariant() })

    # Liste explicite : evite qu'un resultat vide ne devienne @($null) (tableau a 1 element null).
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($site in @($Catalog.sites)) {
        # Filtre pays / region
        if (-not (Test-SiteMatchesCountry -Site $site -Country $Country `
                    -IncludeRestrictedRegions $includeRestricted -RestrictedRegions $restricted)) {
            continue
        }

        # Filtre mot-cle (nom / id / url)
        if (-not [string]::IsNullOrWhiteSpace($Query)) {
            $haystack = @($site.name, $site.id, $site.url) -join ' '
            if ($haystack -notlike "*$Query*") { continue }
        }

        # Filtre categorie au niveau du site (si la categorie n'est pas couverte, on saute)
        if (-not [string]::IsNullOrWhiteSpace($Category)) {
            $siteCats = @()
            if ($site.PSObject.Properties.Name -contains 'categories' -and $null -ne $site.categories) {
                $siteCats = @($site.categories | ForEach-Object { ([string]$_).ToLowerInvariant() })
            }
            if ($siteCats.Count -gt 0 -and $siteCats -notcontains $Category.ToLowerInvariant()) {
                continue
            }
        }

        # Codes valides
        $validCodes = @()
        if ($site.PSObject.Properties.Name -contains 'codes' -and $null -ne $site.codes) {
            $validCodes = @($site.codes | Where-Object {
                $isActive = Test-PromoCodeActive -Code $_ -ReferenceDate $ReferenceDate
                if (-not $isActive) { return $false }
                if ([string]::IsNullOrWhiteSpace($Category)) { return $true }
                # Si le code precise des categories, il doit contenir celle demandee.
                if ($_.PSObject.Properties.Name -contains 'categories' -and $null -ne $_.categories) {
                    $codeCats = @($_.categories | ForEach-Object { ([string]$_).ToLowerInvariant() })
                    return ($codeCats -contains $Category.ToLowerInvariant())
                }
                return $true
            })
        }

        # Offres valides (utilisees si aucun code, ou en complement)
        $offers = @()
        if ($site.PSObject.Properties.Name -contains 'offers' -and $null -ne $site.offers) {
            $offers = @($site.offers | Where-Object {
                $until = if ($_.PSObject.Properties.Name -contains 'validUntil') { ConvertTo-PromoDate $_.validUntil } else { $null }
                ($null -eq $until) -or ($ReferenceDate.Date -le $until)
            })
        }

        $results.Add([pscustomobject]@{
            SiteId       = [string]$site.id
            SiteName     = [string]$site.name
            Url          = if ($site.PSObject.Properties.Name -contains 'url') { [string]$site.url } else { '' }
            Countries    = @($site.countries)
            HasValidCode = ($validCodes.Count -gt 0)
            ValidCodes   = $validCodes
            BestOffers   = $offers
        })
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Gestion du catalogue (ajout / modification / suppression)
# ---------------------------------------------------------------------------

function Add-PromoSite {
    <#
    .SYNOPSIS Ajoute un nouveau site au catalogue puis sauvegarde.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [string]$Url = '',
        [Parameter(Mandatory)][string[]]$Countries,
        [string[]]$Categories = @(),
        [string]$Path
    )

    foreach ($c in $Countries) {
        if (-not (Test-CountryCode -Country $c)) {
            throw "Code pays invalide '$c' (attendu : 2 lettres ou 'ALL')."
        }
    }

    if (-not $Path) { $Path = Get-PromoCatalogPath }
    $catalog = Get-PromoCatalog -Path $Path

    if (@($catalog.sites).Where({ $_.id -eq $Id }, 'First').Count -gt 0) {
        throw "Le site '$Id' existe deja."
    }

    $newSite = [pscustomobject]@{
        id         = $Id
        name       = $Name
        url        = $Url
        countries  = @($Countries | ForEach-Object { $_.ToUpperInvariant() })
        categories = @($Categories | ForEach-Object { $_.ToLowerInvariant() })
        codes      = @()
        offers     = @()
    }
    $catalog.sites = @($catalog.sites) + $newSite

    Save-PromoCatalog -Catalog $catalog -Path $Path
    return $newSite
}

function Get-PromoSiteRef {
    # Helper : retrouve l'objet site (par reference) dans un catalogue, sinon leve.
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$SiteId)
    $site = @($Catalog.sites) | Where-Object { $_.id -eq $SiteId } | Select-Object -First 1
    if ($null -eq $site) { throw "Site introuvable : '$SiteId'." }
    return $site
}

function Add-PromoCode {
    <#
    .SYNOPSIS Ajoute un code promo a un site existant puis sauvegarde.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$Code,
        [string]$Description = '',
        [string]$Discount = '',
        [string]$ValidFrom,
        [string]$ValidUntil,
        [double]$MinPurchase = 0,
        [string[]]$Categories = @(),
        [bool]$Active = $true,
        [string]$Path
    )

    # Validation des dates (leve si format invalide).
    [void](ConvertTo-PromoDate $ValidFrom)
    [void](ConvertTo-PromoDate $ValidUntil)

    if (-not $Path) { $Path = Get-PromoCatalogPath }
    $catalog = Get-PromoCatalog -Path $Path
    $site = Get-PromoSiteRef -Catalog $catalog -SiteId $SiteId

    if (-not ($site.PSObject.Properties.Name -contains 'codes') -or $null -eq $site.codes) {
        $site | Add-Member -NotePropertyName codes -NotePropertyValue @() -Force
    }
    if (@($site.codes).Where({ $_.code -eq $Code }, 'First').Count -gt 0) {
        throw "Le code '$Code' existe deja pour le site '$SiteId'."
    }

    $newCode = [pscustomobject]@{
        code        = $Code
        description = $Description
        discount    = $Discount
        validFrom   = $ValidFrom
        validUntil  = $ValidUntil
        minPurchase = $MinPurchase
        categories  = @($Categories | ForEach-Object { $_.ToLowerInvariant() })
        active      = $Active
    }
    $site.codes = @($site.codes) + $newCode

    Save-PromoCatalog -Catalog $catalog -Path $Path
    return $newCode
}

function Set-PromoCode {
    <#
    .SYNOPSIS Modifie un champ d'un code promo existant (ex: -Active:$false, -ValidUntil).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$Code,
        [string]$Description,
        [string]$Discount,
        [string]$ValidFrom,
        [string]$ValidUntil,
        [Nullable[double]]$MinPurchase,
        [Nullable[bool]]$Active,
        [string]$Path
    )

    if ($PSBoundParameters.ContainsKey('ValidFrom'))  { [void](ConvertTo-PromoDate $ValidFrom) }
    if ($PSBoundParameters.ContainsKey('ValidUntil')) { [void](ConvertTo-PromoDate $ValidUntil) }

    if (-not $Path) { $Path = Get-PromoCatalogPath }
    $catalog = Get-PromoCatalog -Path $Path
    $site = Get-PromoSiteRef -Catalog $catalog -SiteId $SiteId

    $target = @($site.codes) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
    if ($null -eq $target) { throw "Code '$Code' introuvable pour le site '$SiteId'." }

    $map = @{
        Description = 'description'; Discount = 'discount'; ValidFrom = 'validFrom'
        ValidUntil  = 'validUntil'; MinPurchase = 'minPurchase'; Active = 'active'
    }
    foreach ($param in $map.Keys) {
        if ($PSBoundParameters.ContainsKey($param)) {
            $target | Add-Member -NotePropertyName $map[$param] -NotePropertyValue $PSBoundParameters[$param] -Force
        }
    }

    Save-PromoCatalog -Catalog $catalog -Path $Path
    return $target
}

function Remove-PromoCode {
    <#
    .SYNOPSIS Supprime un code promo d'un site puis sauvegarde.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$Code,
        [string]$Path
    )

    if (-not $Path) { $Path = Get-PromoCatalogPath }
    $catalog = Get-PromoCatalog -Path $Path
    $site = Get-PromoSiteRef -Catalog $catalog -SiteId $SiteId

    $remaining = @($site.codes) | Where-Object { $_.code -ne $Code }
    if (@($site.codes).Count -eq @($remaining).Count) {
        throw "Code '$Code' introuvable pour le site '$SiteId'."
    }
    $site.codes = @($remaining)

    Save-PromoCatalog -Catalog $catalog -Path $Path
}

# ---------------------------------------------------------------------------
# Mise a jour automatique depuis des sources (flux JSON HTTPS)
# ---------------------------------------------------------------------------

function Get-PromoSources {
    <#
    .SYNOPSIS Charge la liste des sources de mise a jour (config/sources.json).
    .OUTPUTS Un tableau d'objets { id, url, enabled, description }.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $script:ModuleRoot 'config/sources.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose "Aucun fichier de sources a '$Path'."
        return @()
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json -Depth 10
    } catch {
        throw "Fichier de sources illisible '$Path' : $($_.Exception.Message)"
    }
    if ($obj.PSObject.Properties.Name -contains 'sources' -and $null -ne $obj.sources) {
        return @($obj.sources)
    }
    return @()
}

function Merge-PromoCatalog {
    <#
    .SYNOPSIS Fusionne des donnees source (deja parsees) dans un catalogue, en place.
    .DESCRIPTION
        Fonction pure (sans reseau, testable) : valide la source, ajoute les nouveaux
        sites/codes/offres, met a jour les codes existants (par 'code'), et horodate
        chaque code touche via 'lastChecked'. Le dedoublonnage se fait par identifiant
        de code (par site) et par titre d'offre.
    .OUTPUTS [pscustomobject] { Added; Updated }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Source,
        [datetime]$Today = (Get-Date).Date
    )

    Assert-CatalogSchema -Catalog $Source
    $stamp = $Today.ToString('yyyy-MM-dd')
    $added = 0
    $updated = 0
    $updatableFields = 'description', 'discount', 'validFrom', 'validUntil', 'minPurchase', 'active', 'categories'

    foreach ($srcSite in @($Source.sites)) {
        $site = @($Catalog.sites) | Where-Object { $_.id -eq $srcSite.id } | Select-Object -First 1

        if ($null -eq $site) {
            # Nouveau site : on horodate ses codes puis on l'ajoute tel quel.
            if ($srcSite.PSObject.Properties.Name -contains 'codes' -and $null -ne $srcSite.codes) {
                foreach ($c in @($srcSite.codes)) {
                    $c | Add-Member -NotePropertyName lastChecked -NotePropertyValue $stamp -Force
                }
                $added += @($srcSite.codes).Count
            }
            $Catalog.sites = @($Catalog.sites) + $srcSite
            continue
        }

        if (-not ($site.PSObject.Properties.Name -contains 'codes') -or $null -eq $site.codes) {
            $site | Add-Member -NotePropertyName codes -NotePropertyValue @() -Force
        }

        $srcCodes = if ($srcSite.PSObject.Properties.Name -contains 'codes' -and $null -ne $srcSite.codes) { @($srcSite.codes) } else { @() }
        foreach ($sc in $srcCodes) {
            $existing = @($site.codes) | Where-Object { $_.code -eq $sc.code } | Select-Object -First 1
            if ($null -ne $existing) {
                foreach ($f in $updatableFields) {
                    if ($sc.PSObject.Properties.Name -contains $f) {
                        $existing | Add-Member -NotePropertyName $f -NotePropertyValue $sc.$f -Force
                    }
                }
                $existing | Add-Member -NotePropertyName lastChecked -NotePropertyValue $stamp -Force
                $updated++
            } else {
                $sc | Add-Member -NotePropertyName lastChecked -NotePropertyValue $stamp -Force
                $site.codes = @($site.codes) + $sc
                $added++
            }
        }

        # Fusion des offres par titre (sans doublon).
        if ($srcSite.PSObject.Properties.Name -contains 'offers' -and $null -ne $srcSite.offers) {
            if (-not ($site.PSObject.Properties.Name -contains 'offers') -or $null -eq $site.offers) {
                $site | Add-Member -NotePropertyName offers -NotePropertyValue @() -Force
            }
            foreach ($so in @($srcSite.offers)) {
                $existingOffer = @($site.offers) | Where-Object { $_.title -eq $so.title } | Select-Object -First 1
                if ($null -eq $existingOffer) {
                    $site.offers = @($site.offers) + $so
                    $added++
                }
            }
        }
    }

    return [pscustomobject]@{ Added = $added; Updated = $updated }
}

# ---------------------------------------------------------------------------
# Scraping de sites nommes (Amazon, etc.)
# ---------------------------------------------------------------------------

function Get-PromoScrapers {
    <#
    .SYNOPSIS Charge les definitions de scraping (config/scrapers.json).
    .OUTPUTS Un tableau d'objets scraper.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $script:ModuleRoot 'config/scrapers.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose "Aucun fichier de scrapers a '$Path'."
        return @()
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json -Depth 10
    } catch {
        throw "Fichier de scrapers illisible '$Path' : $($_.Exception.Message)"
    }
    if ($obj.PSObject.Properties.Name -contains 'scrapers' -and $null -ne $obj.scrapers) {
        return @($obj.scrapers)
    }
    return @()
}

function ConvertFrom-ScrapedHtml {
    <#
    .SYNOPSIS Extrait des codes promo d'un HTML selon une definition de scraper (fonction pure, testable).
    .DESCRIPTION
        Applique le motif regex 'codePattern' (groupe nomme obligatoire 'code', groupes
        optionnels 'description' et 'discount') sur le HTML, filtre/dedoublonne les codes,
        et renvoie un objet site au format catalogue. Les codes scrapes recoivent une
        validite glissante (validFrom = aujourd'hui, validUntil = aujourd'hui + N jours)
        afin que les codes disparus expirent d'eux-memes a la prochaine mise a jour.
        Traitement purement textuel : aucune execution du contenu distant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
        [Parameter(Mandatory)]$Scraper,
        [datetime]$Today = (Get-Date).Date
    )

    foreach ($req in 'id', 'name', 'countries', 'codePattern') {
        if (-not ($Scraper.PSObject.Properties.Name -contains $req)) {
            throw "Scraper invalide : champ obligatoire '$req' manquant."
        }
    }
    foreach ($c in @($Scraper.countries)) {
        if (-not (Test-CountryCode -Country ([string]$c))) {
            throw "Scraper '$($Scraper.id)' : code pays invalide '$c'."
        }
    }

    $maxCodes = if ($Scraper.PSObject.Properties.Name -contains 'maxCodes' -and $Scraper.maxCodes) { [int]$Scraper.maxCodes } else { 50 }
    $validity = if ($Scraper.PSObject.Properties.Name -contains 'defaultValidityDays' -and $Scraper.defaultValidityDays) { [int]$Scraper.defaultValidityDays } else { 30 }
    $categories = if ($Scraper.PSObject.Properties.Name -contains 'categories' -and $null -ne $Scraper.categories) { @($Scraper.categories) } else { @() }
    # Liste blanche du format d'un code valide (anti-bruit) : alphanumerique + tirets, 3 a 20 caracteres.
    $allow = if ($Scraper.PSObject.Properties.Name -contains 'codeAllowPattern' -and $Scraper.codeAllowPattern) { [string]$Scraper.codeAllowPattern } else { '^[A-Za-z0-9][A-Za-z0-9\-]{2,19}$' }

    $stamp = $Today.ToString('yyyy-MM-dd')
    $until = $Today.AddDays($validity).ToString('yyyy-MM-dd')

    $codes = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not [string]::IsNullOrEmpty($Html)) {
        $regex = [regex]::new([string]$Scraper.codePattern,
            ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant),
            [timespan]::FromSeconds(5))  # timeout regex : protege contre les motifs catastrophiques
        try {
            $matchList = $regex.Matches($Html)
        } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
            throw "Scraper '$($Scraper.id)' : delai d'analyse regex depasse (motif trop couteux)."
        }

        foreach ($m in $matchList) {
            if ($codes.Count -ge $maxCodes) { break }
            if (-not $m.Groups['code'].Success) { continue }
            $code = $m.Groups['code'].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($code)) { continue }
            if ($code -notmatch $allow) { continue }
            if (-not $seen.Add($code)) { continue }

            $desc = if ($m.Groups['description'].Success) { $m.Groups['description'].Value.Trim() } else { "Code recupere automatiquement sur $($Scraper.name)" }
            $disc = if ($m.Groups['discount'].Success) { $m.Groups['discount'].Value.Trim() } else { '' }

            $codes.Add([pscustomobject]@{
                code        = $code
                description = $desc
                discount    = $disc
                validFrom   = $stamp
                validUntil  = $until
                minPurchase = 0
                categories  = $categories
                active      = $true
                source      = 'scrape'
                lastChecked = $stamp
            })
        }
    }

    return [pscustomobject]@{
        id         = [string]$Scraper.id
        name       = [string]$Scraper.name
        url        = if ($Scraper.PSObject.Properties.Name -contains 'url') { [string]$Scraper.url } else { '' }
        countries  = @($Scraper.countries)
        categories = $categories
        codes      = $codes.ToArray()
        offers     = @()
    }
}

function Invoke-PromoScraper {
    <#
    .SYNOPSIS Telecharge la page d'un scraper (HTTPS) et en extrait les codes.
    .OUTPUTS Un objet site au format catalogue.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Scraper,
        [int]$TimeoutSec = 20,
        [datetime]$Today = (Get-Date).Date
    )

    $url = if ($Scraper.PSObject.Properties.Name -contains 'url') { [string]$Scraper.url } else { '' }
    if ($url -notmatch '^https://') {
        throw "Scraper '$($Scraper.id)' : URL non HTTPS '$url' (HTTPS obligatoire)."
    }

    $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -MaximumRedirection 3 `
        -Headers @{ 'User-Agent' = 'PromoAggregator/1.0 (+promo-scraper)' }
    $html = [string]$resp.Content

    return ConvertFrom-ScrapedHtml -Html $html -Scraper $Scraper -Today $Today
}

function Add-PromoScraper {
    <#
    .SYNOPSIS Ajoute (ou remplace) la definition de scraping d'un site nomme, puis sauvegarde.
    .EXAMPLE
        Add-PromoScraper -Id amazon-fr -Name 'Amazon France' -Url 'https://www.amazon.fr/promotions' `
            -Countries FR -CodePattern '(?<code>[A-Z0-9]{6,12})'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string[]]$Countries,
        [Parameter(Mandatory)][string]$CodePattern,
        [string[]]$Categories = @('general'),
        [int]$DefaultValidityDays = 30,
        [int]$MaxCodes = 50,
        [bool]$Enabled = $true,
        [string]$Path
    )

    if ($Url -notmatch '^https://') { throw "URL non HTTPS '$Url' (HTTPS obligatoire)." }
    foreach ($c in $Countries) {
        if (-not (Test-CountryCode -Country $c)) { throw "Code pays invalide '$c'." }
    }
    # Valide le motif regex immediatement (leve si invalide).
    [void][regex]::new($CodePattern)

    if (-not $Path) { $Path = Join-Path $script:ModuleRoot 'config/scrapers.json' }

    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $doc = $raw | ConvertFrom-Json -Depth 10
    } else {
        $doc = [pscustomobject]@{ schemaVersion = '1.0'; scrapers = @() }
    }
    if (-not ($doc.PSObject.Properties.Name -contains 'scrapers') -or $null -eq $doc.scrapers) {
        $doc | Add-Member -NotePropertyName scrapers -NotePropertyValue @() -Force
    }

    $entry = [pscustomobject]@{
        id                  = $Id
        name                = $Name
        url                 = $Url
        countries           = @($Countries | ForEach-Object { $_.ToUpperInvariant() })
        categories          = @($Categories | ForEach-Object { $_.ToLowerInvariant() })
        codePattern         = $CodePattern
        defaultValidityDays = $DefaultValidityDays
        maxCodes            = $MaxCodes
        enabled             = $Enabled
    }

    $others = @($doc.scrapers | Where-Object { $_.id -ne $Id })
    $doc.scrapers = @($others) + $entry

    if ($PSCmdlet.ShouldProcess($Path, "Enregistrer le scraper '$Id'")) {
        $json = $doc | ConvertTo-Json -Depth 20
        $tmp = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    return $entry
}

function Update-PromoCatalog {
    <#
    .SYNOPSIS Recupere les sources (HTTPS), les fusionne dans le catalogue et sauvegarde.
    .DESCRIPTION
        Pour chaque source activee de config/sources.json : telecharge le flux JSON
        (HTTPS uniquement), le valide (schema), puis le fusionne. Les sources
        injoignables ou invalides sont ignorees sans interrompre la mise a jour.
        Enregistre la date du jour dans 'lastUpdated' a la racine du catalogue.
    .OUTPUTS [pscustomobject] { Added; Updated; Sources; Failed; LastUpdated }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$CatalogPath,
        [string]$SourcesPath,
        [string]$ScrapersPath,
        [int]$TimeoutSec = 20
    )

    if (-not $CatalogPath)  { $CatalogPath  = Get-PromoCatalogPath }
    if (-not $SourcesPath)  { $SourcesPath  = Join-Path $script:ModuleRoot 'config/sources.json' }
    if (-not $ScrapersPath) { $ScrapersPath = Join-Path $script:ModuleRoot 'config/scrapers.json' }

    $catalog = Get-PromoCatalog -Path $CatalogPath
    $sources = Get-PromoSources -Path $SourcesPath
    $today = (Get-Date).Date
    $added = 0; $updated = 0; $okSources = 0; $failed = 0

    foreach ($src in $sources) {
        if ($src.PSObject.Properties.Name -contains 'enabled' -and -not $src.enabled) { continue }

        $url = if ($src.PSObject.Properties.Name -contains 'url') { [string]$src.url } else { '' }
        # Securite : HTTPS uniquement, pas d'autre schema (file://, http://, etc.).
        if ($url -notmatch '^https://') {
            Write-Warning "Source ignoree (HTTPS obligatoire) : '$url'"
            $failed++
            continue
        }

        try {
            $data = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -MaximumRedirection 2 `
                -Headers @{ 'User-Agent' = 'PromoAggregator/1.0 (+catalog-updater)' }
        } catch {
            Write-Warning "Source injoignable : '$url' -> $($_.Exception.Message)"
            $failed++
            continue
        }

        try {
            # Donnees externes = non fiables : validees par le schema avant fusion.
            $res = Merge-PromoCatalog -Catalog $catalog -Source $data -Today $today
            $added += $res.Added
            $updated += $res.Updated
            $okSources++
        } catch {
            Write-Warning "Source invalide : '$url' -> $($_.Exception.Message)"
            $failed++
            continue
        }
    }

    # --- Scrapers de sites nommes (Amazon, etc.) ---------------------------
    foreach ($scraper in (Get-PromoScrapers -Path $ScrapersPath)) {
        if ($scraper.PSObject.Properties.Name -contains 'enabled' -and -not $scraper.enabled) { continue }
        $sid = if ($scraper.PSObject.Properties.Name -contains 'id') { [string]$scraper.id } else { '?' }

        try {
            $site = Invoke-PromoScraper -Scraper $scraper -TimeoutSec $TimeoutSec -Today $today
        } catch {
            Write-Warning "Scraper '$sid' injoignable/invalide : $($_.Exception.Message)"
            $failed++
            continue
        }

        try {
            $wrapped = [pscustomobject]@{ schemaVersion = '1.0'; sites = @($site) }
            $res = Merge-PromoCatalog -Catalog $catalog -Source $wrapped -Today $today
            $added += $res.Added
            $updated += $res.Updated
            if (@($site.codes).Count -gt 0) { $okSources++ }
            Write-Verbose "Scraper '$sid' : $(@($site.codes).Count) code(s) extrait(s)."
        } catch {
            Write-Warning "Scraper '$sid' : fusion impossible -> $($_.Exception.Message)"
            $failed++
            continue
        }
    }

    $catalog | Add-Member -NotePropertyName lastUpdated -NotePropertyValue $today.ToString('yyyy-MM-dd') -Force

    if ($PSCmdlet.ShouldProcess($CatalogPath, 'Enregistrer le catalogue mis a jour')) {
        Save-PromoCatalog -Catalog $catalog -Path $CatalogPath
    }

    return [pscustomobject]@{
        Added       = $added
        Updated     = $updated
        Sources     = $okSources
        Failed      = $failed
        LastUpdated = $today.ToString('yyyy-MM-dd')
    }
}

# ---------------------------------------------------------------------------
# Suivi de prix et alertes (PS5, etc.)
# ---------------------------------------------------------------------------

function ConvertTo-Price {
    <#
    .SYNOPSIS Normalise une chaine de prix en [decimal] (gere formats europeen et anglo-saxon).
    .DESCRIPTION
        Exemples : '599,99 EUR' -> 599.99 ; '1 199,99' -> 1199.99 ; '$1,299.00' -> 1299.00 ;
        '1.299,00' -> 1299.00. Retourne $null si non interpretable.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[decimal]])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $s = ($Text -replace '[^\d.,]', '')   # ne garder que chiffres, point, virgule
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }

    $hasComma = $s.Contains(',')
    $hasDot = $s.Contains('.')

    if ($hasComma -and $hasDot) {
        if ($s.LastIndexOf(',') -gt $s.LastIndexOf('.')) {
            # virgule decimale (europeen) : '.' = milliers
            $s = ($s -replace '\.', '') -replace ',', '.'
        } else {
            # point decimal (anglo) : ',' = milliers
            $s = $s -replace ',', ''
        }
    } elseif ($hasComma) {
        $parts = $s.Split(',')
        if ($parts.Count -eq 2 -and $parts[1].Length -le 2) {
            $s = $s -replace ',', '.'   # decimale
        } else {
            $s = $s -replace ',', ''    # milliers
        }
    } elseif ($hasDot) {
        $parts = $s.Split('.')
        if ($parts.Count -gt 2) {
            $s = $s -replace '\.', ''   # plusieurs points => milliers
        } elseif ($parts.Count -eq 2 -and $parts[1].Length -eq 3 -and $parts[0].Length -le 3) {
            $s = $s -replace '\.', ''   # ex '1.199' => 1199 (millier), pas une decimale
        }
        # sinon le point reste decimal
    }

    $out = [decimal]0
    if ([decimal]::TryParse($s, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) {
        return $out
    }
    return $null
}

function ConvertFrom-ScrapedPrice {
    <#
    .SYNOPSIS Extrait un prix d'un HTML via une regex (groupe nomme 'price'). Fonction pure, testable.
    .OUTPUTS [decimal] ou $null si non trouve.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[decimal]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ([string]::IsNullOrEmpty($Html)) { return $null }
    $regex = [regex]::new($Pattern,
        ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase `
            -bor [System.Text.RegularExpressions.RegexOptions]::Singleline `
            -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant),
        [timespan]::FromSeconds(5))
    try {
        $m = $regex.Match($Html)
    } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        throw "Motif de prix trop couteux (timeout regex)."
    }
    if (-not $m.Success) { return $null }
    $raw = if ($m.Groups['price'].Success) { $m.Groups['price'].Value } else { $m.Value }
    return ConvertTo-Price -Text $raw
}

function Compare-PriceChange {
    <#
    .SYNOPSIS Compare un ancien et un nouveau prix et qualifie la variation (baisse/hausse/stable).
    .OUTPUTS [pscustomobject] { Changed; Direction; Percent; Delta }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][Nullable[decimal]]$OldPrice,
        [Parameter(Mandatory)][decimal]$NewPrice,
        [double]$ThresholdPercent = 0
    )

    if ($null -eq $OldPrice) {
        return [pscustomobject]@{ Changed = $false; Direction = 'nouveau'; Percent = 0.0; Delta = [decimal]0 }
    }
    $delta = $NewPrice - $OldPrice
    if ($delta -eq 0 -or $OldPrice -eq 0) {
        return [pscustomobject]@{ Changed = $false; Direction = 'stable'; Percent = 0.0; Delta = $delta }
    }
    $pct = [math]::Round([double]($delta / $OldPrice) * 100.0, 2)
    $direction = if ($delta -lt 0) { 'baisse' } else { 'hausse' }
    $changed = [math]::Abs($pct) -ge $ThresholdPercent
    return [pscustomobject]@{ Changed = $changed; Direction = $direction; Percent = $pct; Delta = $delta }
}

function Get-PromoProducts {
    <#
    .SYNOPSIS Charge la liste des produits suivis (config/products.json).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $script:ModuleRoot 'config/products.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ schemaVersion = '1.0'; products = @() }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json -Depth 20
    } catch {
        throw "Fichier produits illisible '$Path' : $($_.Exception.Message)"
    }
    if (-not ($obj.PSObject.Properties.Name -contains 'products') -or $null -eq $obj.products) {
        throw "Fichier produits invalide : cle 'products' manquante."
    }
    foreach ($p in @($obj.products)) {
        foreach ($req in 'id', 'name', 'sites') {
            if (-not ($p.PSObject.Properties.Name -contains $req)) {
                throw "Produit invalide : champ '$req' manquant."
            }
        }
    }
    return $obj
}

function Get-PriceHistory {
    <#
    .SYNOPSIS Charge l'historique des prix (data/price-history.json).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $script:ModuleRoot 'data/price-history.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ schemaVersion = '1.0'; entries = @() }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json -Depth 20
    } catch {
        throw "Historique des prix illisible '$Path' : $($_.Exception.Message)"
    }
    if (-not ($obj.PSObject.Properties.Name -contains 'entries') -or $null -eq $obj.entries) {
        $obj | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force
    }
    return $obj
}

function Save-PriceHistory {
    <#
    .SYNOPSIS Sauvegarde l'historique des prix (ecriture atomique UTF-8).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$History, [string]$Path)

    if (-not $Path) { $Path = Join-Path $script:ModuleRoot 'data/price-history.json' }
    if ($PSCmdlet.ShouldProcess($Path, 'Ecrire l''historique des prix')) {
        $json = $History | ConvertTo-Json -Depth 20
        $tmp = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}

function Send-PriceAlert {
    <#
    .SYNOPSIS Notifie une variation de prix : console + fichier d'alertes + webhook/toast optionnels.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Alert,
        [pscustomobject]$Config,
        [string]$AlertsPath
    )

    if (-not $Config) { $Config = Get-PromoConfig }
    if (-not $AlertsPath) { $AlertsPath = Join-Path $script:ModuleRoot 'data/alerts.json' }

    $symbol = if ($Alert.Direction -eq 'baisse') { 'BAISSE v' } else { 'HAUSSE ^' }
    $message = "[ALERTE PRIX] {0} | {1} sur {2} : {3} -> {4} EUR ({5}{6}%)" -f `
        $symbol, $Alert.ProductName, $Alert.Site, $Alert.OldPrice, $Alert.NewPrice, `
        $(if ($Alert.Percent -gt 0) { '+' } else { '' }), $Alert.Percent

    # 1) Console (couleur selon le sens)
    $color = if ($Alert.Direction -eq 'baisse') { 'Green' } else { 'Red' }
    Write-Host $message -ForegroundColor $color
    if ($Alert.Url) { Write-Host "          $($Alert.Url)" -ForegroundColor DarkGray }

    # 2) Fichier d'alertes (journal, plafonne a 200 entrees)
    try {
        $doc = if (Test-Path -LiteralPath $AlertsPath) {
            Get-Content -LiteralPath $AlertsPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        } else {
            [pscustomobject]@{ schemaVersion = '1.0'; alerts = @() }
        }
        if (-not ($doc.PSObject.Properties.Name -contains 'alerts') -or $null -eq $doc.alerts) {
            $doc | Add-Member -NotePropertyName alerts -NotePropertyValue @() -Force
        }
        $doc.alerts = @(@($doc.alerts) + $Alert | Select-Object -Last 200)
        if ($PSCmdlet.ShouldProcess($AlertsPath, 'Journaliser l''alerte')) {
            $tmp = "$AlertsPath.tmp"
            [System.IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tmp -Destination $AlertsPath -Force
        }
    } catch {
        Write-Warning "Impossible de journaliser l'alerte : $($_.Exception.Message)"
    }

    # 3) Webhook optionnel (HTTPS uniquement) : config ou variable d'environnement
    $hook = ''
    if ($Config.PSObject.Properties.Name -contains 'alertWebhookUrl' -and $Config.alertWebhookUrl) {
        $hook = [string]$Config.alertWebhookUrl
    } elseif ($env:PROMO_ALERT_WEBHOOK) {
        $hook = [string]$env:PROMO_ALERT_WEBHOOK
    }
    if ($hook -match '^https://') {
        try {
            Invoke-RestMethod -Method Post -Uri $hook -TimeoutSec 10 -ContentType 'application/json; charset=utf-8' `
                -Body (@{ content = $message } | ConvertTo-Json) | Out-Null
        } catch {
            Write-Warning "Webhook d'alerte injoignable : $($_.Exception.Message)"
        }
    }

    # 4) Notification Windows (best-effort, si BurntToast est installe)
    if ($IsWindows) {
        try {
            if (Get-Module -ListAvailable -Name BurntToast) {
                Import-Module BurntToast -ErrorAction Stop
                New-BurntToastNotification -Text 'Alerte prix', $message -ErrorAction Stop
            }
        } catch {
            Write-Verbose "Notification toast indisponible : $($_.Exception.Message)"
        }
    }
}

function Update-PriceWatch {
    <#
    .SYNOPSIS Releve le prix des produits suivis, detecte les variations et declenche les alertes.
    .DESCRIPTION
        Pour chaque produit (config/products.json) et chaque site active : telecharge la page
        (HTTPS), extrait le prix, le compare au dernier prix connu (data/price-history.json),
        met a jour l'historique et envoie une alerte en cas de baisse ou de hausse (selon
        'alertThresholdPercent'). Les pages injoignables ou sans prix sont ignorees sans
        interrompre le suivi.
    .OUTPUTS [pscustomobject] { Checked; Alerts; Failed; Notifications }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$ProductsPath,
        [string]$HistoryPath,
        [pscustomobject]$Config,
        [int]$TimeoutSec = 20,
        [switch]$NoAlert
    )

    if (-not $Config) { $Config = Get-PromoConfig }
    if (-not $HistoryPath) { $HistoryPath = Join-Path $script:ModuleRoot 'data/price-history.json' }

    $products = Get-PromoProducts -Path $ProductsPath
    $history = Get-PriceHistory -Path $HistoryPath
    $today = (Get-Date).Date
    $stamp = $today.ToString('yyyy-MM-dd')
    $checked = 0; $failed = 0
    $alerts = [System.Collections.Generic.List[object]]::new()

    foreach ($product in @($products.products)) {
        $threshold = if ($product.PSObject.Properties.Name -contains 'alertThresholdPercent') { [double]$product.alertThresholdPercent } else { 0.0 }

        foreach ($site in @($product.sites)) {
            if ($site.PSObject.Properties.Name -contains 'enabled' -and -not $site.enabled) { continue }
            $siteId = if ($site.PSObject.Properties.Name -contains 'site') { [string]$site.site } else { '?' }
            $url = if ($site.PSObject.Properties.Name -contains 'url') { [string]$site.url } else { '' }
            $pattern = if ($site.PSObject.Properties.Name -contains 'pricePattern') { [string]$site.pricePattern } else { '' }

            if ($url -notmatch '^https://') { Write-Warning "Produit '$($product.id)'/$siteId : URL non HTTPS ignoree."; $failed++; continue }
            if ([string]::IsNullOrWhiteSpace($pattern)) { Write-Warning "Produit '$($product.id)'/$siteId : pricePattern manquant."; $failed++; continue }

            try {
                $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -MaximumRedirection 3 `
                    -Headers @{ 'User-Agent' = 'PromoAggregator/1.0 (+price-watch)' }
                $price = ConvertFrom-ScrapedPrice -Html ([string]$resp.Content) -Pattern $pattern
            } catch {
                Write-Warning "Produit '$($product.id)'/$siteId : page injoignable -> $($_.Exception.Message)"
                $failed++
                continue
            }
            if ($null -eq $price) { Write-Warning "Produit '$($product.id)'/$siteId : prix introuvable sur la page."; $failed++; continue }

            $checked++
            $key = "$($product.id)|$siteId"
            $entry = @($history.entries) | Where-Object { $_.key -eq $key } | Select-Object -First 1
            $old = if ($entry -and ($entry.PSObject.Properties.Name -contains 'lastPrice')) { [decimal]$entry.lastPrice } else { $null }

            $cmp = Compare-PriceChange -OldPrice $old -NewPrice $price -ThresholdPercent $threshold

            if ($null -eq $entry) {
                $entry = [pscustomobject]@{
                    key = $key; productId = [string]$product.id; productName = [string]$product.name
                    site = $siteId; url = $url; lastPrice = $price; currency = 'EUR'
                    lastChecked = $stamp; history = @()
                }
                $history.entries = @(@($history.entries) + $entry)
            } else {
                $entry | Add-Member -NotePropertyName lastPrice -NotePropertyValue $price -Force
                $entry | Add-Member -NotePropertyName lastChecked -NotePropertyValue $stamp -Force
                $entry | Add-Member -NotePropertyName url -NotePropertyValue $url -Force
            }
            if (-not ($entry.PSObject.Properties.Name -contains 'history') -or $null -eq $entry.history) {
                $entry | Add-Member -NotePropertyName history -NotePropertyValue @() -Force
            }
            $entry.history = @(@($entry.history) + [pscustomobject]@{ date = $stamp; price = $price } | Select-Object -Last 60)

            if ($cmp.Changed) {
                $alerts.Add([pscustomobject]@{
                    ProductId = [string]$product.id; ProductName = [string]$product.name
                    Site = $siteId; Url = $url; OldPrice = $old; NewPrice = $price
                    Direction = $cmp.Direction; Percent = $cmp.Percent; Date = $stamp
                })
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($HistoryPath, 'Enregistrer l''historique des prix')) {
        Save-PriceHistory -History $history -Path $HistoryPath
    }

    $notified = 0
    if (-not $NoAlert) {
        foreach ($a in $alerts) { Send-PriceAlert -Alert $a -Config $Config; $notified++ }
    }

    return [pscustomobject]@{
        Checked       = $checked
        Alerts        = $alerts.ToArray()
        Failed        = $failed
        Notifications = $notified
    }
}

Export-ModuleMember -Function @(
    'Get-PromoConfig', 'Get-PromoCatalogPath', 'Get-PromoCatalog', 'Save-PromoCatalog',
    'Test-PromoCodeActive', 'Test-SiteMatchesCountry', 'Test-CountryCode', 'ConvertTo-PromoDate',
    'Find-PromoCode', 'Add-PromoSite', 'Add-PromoCode', 'Set-PromoCode', 'Remove-PromoCode',
    'Get-PromoSources', 'Merge-PromoCatalog', 'Update-PromoCatalog',
    'Get-PromoScrapers', 'ConvertFrom-ScrapedHtml', 'Invoke-PromoScraper', 'Add-PromoScraper',
    'ConvertTo-Price', 'ConvertFrom-ScrapedPrice', 'Compare-PriceChange',
    'Get-PromoProducts', 'Get-PriceHistory', 'Save-PriceHistory', 'Update-PriceWatch', 'Send-PriceAlert'
)
