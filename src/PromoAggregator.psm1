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
        [int]$TimeoutSec = 20
    )

    if (-not $CatalogPath) { $CatalogPath = Get-PromoCatalogPath }
    if (-not $SourcesPath) { $SourcesPath = Join-Path $script:ModuleRoot 'config/sources.json' }

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

Export-ModuleMember -Function @(
    'Get-PromoConfig', 'Get-PromoCatalogPath', 'Get-PromoCatalog', 'Save-PromoCatalog',
    'Test-PromoCodeActive', 'Test-SiteMatchesCountry', 'Test-CountryCode', 'ConvertTo-PromoDate',
    'Find-PromoCode', 'Add-PromoSite', 'Add-PromoCode', 'Set-PromoCode', 'Remove-PromoCode',
    'Get-PromoSources', 'Merge-PromoCatalog', 'Update-PromoCatalog'
)
