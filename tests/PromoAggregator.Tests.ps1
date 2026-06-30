#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Suite de tests Pester pour PromoAggregator.
    Execution : Invoke-Pester ./tests/PromoAggregator.Tests.ps1
    (Necessite Pester 5+. Pour un environnement sans Pester, voir tests/Invoke-Checks.ps1.)
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $Root 'src/PromoAggregator.psd1') -Force

    # Catalogue de test isole (n'altere pas data/promo-codes.json)
    $script:TmpCatalog = Join-Path ([System.IO.Path]::GetTempPath()) ("promo-test-{0}.json" -f ([guid]::NewGuid()))
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
    ($fixture | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $TmpCatalog -Encoding utf8
    $script:Catalog = Get-PromoCatalog -Path $TmpCatalog
    $script:Ref = [datetime]'2026-06-30'
}

AfterAll {
    if (Test-Path -LiteralPath $script:TmpCatalog) { Remove-Item -LiteralPath $script:TmpCatalog -Force }
}

Describe 'Test-CountryCode' {
    It 'accepte ALL et codes ISO 2 lettres' {
        Test-CountryCode 'ALL' | Should -BeTrue
        Test-CountryCode 'FR'  | Should -BeTrue
        Test-CountryCode 'cn'  | Should -BeTrue
    }
    It 'rejette les valeurs invalides' {
        Test-CountryCode 'FRA' | Should -BeFalse
        Test-CountryCode '12'  | Should -BeFalse
        Test-CountryCode ''    | Should -BeFalse
    }
}

Describe 'ConvertTo-PromoDate' {
    It 'parse une date ISO valide' {
        (ConvertTo-PromoDate '2026-06-30') | Should -Be ([datetime]'2026-06-30')
    }
    It 'renvoie null pour une valeur vide' {
        (ConvertTo-PromoDate '') | Should -BeNullOrEmpty
    }
    It 'leve une exception pour un format invalide' {
        { ConvertTo-PromoDate '30/06/2026' } | Should -Throw
    }
}

Describe 'Test-PromoCodeActive' {
    It 'valide un code dans sa fenetre' {
        $code = ($script:Catalog.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'OK10'
        Test-PromoCodeActive -Code $code -ReferenceDate $script:Ref | Should -BeTrue
    }
    It 'rejette un code expire' {
        $code = ($script:Catalog.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'OLD'
        Test-PromoCodeActive -Code $code -ReferenceDate $script:Ref | Should -BeFalse
    }
    It 'rejette un code desactive' {
        $code = ($script:Catalog.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'OFF'
        Test-PromoCodeActive -Code $code -ReferenceDate $script:Ref | Should -BeFalse
    }
}

Describe 'Test-SiteMatchesCountry' {
    BeforeEach {
        $script:SiteFr = $script:Catalog.sites | Where-Object id -eq 'shop-fr'
        $script:SiteCn = $script:Catalog.sites | Where-Object id -eq 'shop-cn'
    }
    It 'ALL renvoie tous les sites' {
        Test-SiteMatchesCountry -Site $script:SiteCn -Country 'ALL' | Should -BeTrue
    }
    It 'filtre par pays exact' {
        Test-SiteMatchesCountry -Site $script:SiteFr -Country 'FR' | Should -BeTrue
        Test-SiteMatchesCountry -Site $script:SiteFr -Country 'US' -IncludeRestrictedRegions $false | Should -BeFalse
    }
    It 'inclut la Chine quand IncludeRestrictedRegions est actif' {
        Test-SiteMatchesCountry -Site $script:SiteCn -Country 'FR' -IncludeRestrictedRegions $true | Should -BeTrue
    }
    It 'exclut la Chine quand IncludeRestrictedRegions est desactive' {
        Test-SiteMatchesCountry -Site $script:SiteCn -Country 'FR' -IncludeRestrictedRegions $false | Should -BeFalse
    }
}

Describe 'Find-PromoCode' {
    It 'ne renvoie que les codes valides' {
        $res = Find-PromoCode -Country 'FR' -Catalog $script:Catalog -ReferenceDate $script:Ref
        $fr = $res | Where-Object SiteId -eq 'shop-fr'
        @($fr.ValidCodes).Count | Should -Be 1
        $fr.ValidCodes[0].code | Should -Be 'OK10'
    }
    It 'propose des offres quand aucun code valide' {
        $res = Find-PromoCode -Country 'CN' -Catalog $script:Catalog -ReferenceDate $script:Ref
        $cn = $res | Where-Object SiteId -eq 'shop-cn'
        $cn.HasValidCode | Should -BeFalse
        @($cn.BestOffers).Count | Should -BeGreaterThan 0
    }
    It 'filtre par categorie' {
        $res = Find-PromoCode -Category 'mode' -Worldwide -Catalog $script:Catalog -ReferenceDate $script:Ref
        ($res | Where-Object SiteId -eq 'shop-fr') | Should -BeNullOrEmpty
        ($res | Where-Object SiteId -eq 'shop-cn') | Should -Not -BeNullOrEmpty
    }
    It 'rejette un filtre pays invalide' {
        { Find-PromoCode -Country 'XXX' -Catalog $script:Catalog } | Should -Throw
    }
}

Describe 'Gestion du catalogue (ecriture)' {
    It 'ajoute, modifie et supprime un code' {
        Add-PromoCode -SiteId 'shop-fr' -Code 'NEW20' -Discount '-20%' -ValidFrom '2026-01-01' -ValidUntil '2026-12-31' -Path $script:TmpCatalog | Out-Null
        $cat = Get-PromoCatalog -Path $script:TmpCatalog
        (($cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'NEW20') | Should -Not -BeNullOrEmpty

        Set-PromoCode -SiteId 'shop-fr' -Code 'NEW20' -Active $false -Path $script:TmpCatalog | Out-Null
        $cat = Get-PromoCatalog -Path $script:TmpCatalog
        (($cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'NEW20').active | Should -BeFalse

        Remove-PromoCode -SiteId 'shop-fr' -Code 'NEW20' -Path $script:TmpCatalog
        $cat = Get-PromoCatalog -Path $script:TmpCatalog
        (($cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'NEW20') | Should -BeNullOrEmpty
    }
    It 'refuse un code en doublon' {
        { Add-PromoCode -SiteId 'shop-fr' -Code 'OK10' -Path $script:TmpCatalog } | Should -Throw
    }
    It 'refuse un site inexistant' {
        { Add-PromoCode -SiteId 'inconnu' -Code 'ZZZ' -Path $script:TmpCatalog } | Should -Throw
    }
}

Describe 'Merge-PromoCatalog (mise a jour)' {
    BeforeEach {
        $script:Cat = Get-PromoCatalog -Path $script:TmpCatalog
        $script:Day = [datetime]'2026-06-30'
    }
    It 'ajoute un nouveau code et l''horodate' {
        $src = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-fr'; name = 'Shop FR'; countries = @('FR'); codes = @(@{ code = 'FRESH'; discount = '-30%'; validFrom = '2026-01-01'; validUntil = '2026-12-31'; active = $true }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $r = Merge-PromoCatalog -Catalog $script:Cat -Source $src -Today $script:Day
        $r.Added | Should -BeGreaterThan 0
        $code = ($script:Cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'FRESH'
        $code.lastChecked | Should -Be '2026-06-30'
    }
    It 'met a jour un code existant' {
        $src = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-fr'; name = 'Shop FR'; countries = @('FR'); codes = @(@{ code = 'OK10'; discount = '-99%'; validUntil = '2027-01-01'; active = $true }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $r = Merge-PromoCatalog -Catalog $script:Cat -Source $src -Today $script:Day
        $r.Updated | Should -BeGreaterThan 0
        (($script:Cat.sites | Where-Object id -eq 'shop-fr').codes | Where-Object code -eq 'OK10').discount | Should -Be '-99%'
    }
    It 'ajoute un nouveau site' {
        $src = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-us'; name = 'Shop US'; countries = @('US'); codes = @(@{ code = 'USA5'; active = $true }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Merge-PromoCatalog -Catalog $script:Cat -Source $src -Today $script:Day | Out-Null
        ($script:Cat.sites | Where-Object id -eq 'shop-us') | Should -Not -BeNullOrEmpty
    }
    It 'ne duplique pas une offre existante' {
        $before = @(($script:Cat.sites | Where-Object id -eq 'shop-fr').offers).Count
        $src = @{ schemaVersion = '1.0'; sites = @(@{ id = 'shop-fr'; name = 'Shop FR'; countries = @('FR'); offers = @(@{ title = 'Soldes'; description = 'doublon' }) }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Merge-PromoCatalog -Catalog $script:Cat -Source $src -Today $script:Day | Out-Null
        @(($script:Cat.sites | Where-Object id -eq 'shop-fr').offers).Count | Should -Be $before
    }
    It 'rejette une source au schema invalide' {
        $bad = @{ sites = @(@{ name = 'sans id'; countries = @('FR') }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        { Merge-PromoCatalog -Catalog $script:Cat -Source $bad -Today $script:Day } | Should -Throw
    }
}

Describe 'ConvertFrom-ScrapedHtml (scraping)' {
    BeforeAll {
        $script:Scraper = [pscustomobject]@{
            id = 'test-shop'; name = 'Test Shop'; url = 'https://test.example'
            countries = @('FR'); categories = @('general')
            codePattern = '(?i)code[^A-Za-z0-9]{0,5}(?<code>[A-Z0-9]{4,12})'
            defaultValidityDays = 15; maxCodes = 10
        }
        $script:Html = 'Promo CODE: SUMMER20 ... CODE WELCOME10 ... doublon CODE: SUMMER20 ... bruit CODE: AB'
        $script:Day = [datetime]'2026-06-30'
    }
    It 'extrait et dedoublonne les codes valides' {
        $site = ConvertFrom-ScrapedHtml -Html $script:Html -Scraper $script:Scraper -Today $script:Day
        @($site.codes).Count | Should -Be 2
        @($site.codes.code) | Should -Contain 'SUMMER20'
        @($site.codes.code) | Should -Contain 'WELCOME10'
    }
    It 'applique une validite glissante et marque la source' {
        $site = ConvertFrom-ScrapedHtml -Html $script:Html -Scraper $script:Scraper -Today $script:Day
        $c = $site.codes | Select-Object -First 1
        $c.validFrom  | Should -Be '2026-06-30'
        $c.validUntil | Should -Be '2026-07-15'
        $c.source     | Should -Be 'scrape'
    }
    It 'gere un HTML vide sans erreur' {
        $site = ConvertFrom-ScrapedHtml -Html '' -Scraper $script:Scraper -Today $script:Day
        @($site.codes).Count | Should -Be 0
    }
    It 'respecte maxCodes' {
        $sc2 = $script:Scraper.PSObject.Copy(); $sc2.maxCodes = 1
        (ConvertFrom-ScrapedHtml -Html $script:Html -Scraper $sc2 -Today $script:Day).codes.Count | Should -Be 1
    }
    It 'leve si codePattern manquant' {
        $bad = [pscustomobject]@{ id = 'x'; name = 'X'; countries = @('FR') }
        { ConvertFrom-ScrapedHtml -Html $script:Html -Scraper $bad } | Should -Throw
    }
}

Describe 'Prix : normalisation et detection' {
    It 'normalise les formats de prix' {
        ConvertTo-Price '599,99 EUR' | Should -Be ([decimal]599.99)
        ConvertTo-Price '1 199,99'   | Should -Be ([decimal]1199.99)
        ConvertTo-Price '$1,299.00'  | Should -Be ([decimal]1299.00)
        ConvertTo-Price '1.299,00'   | Should -Be ([decimal]1299.00)
        ConvertTo-Price '799'        | Should -Be ([decimal]799)
        ConvertTo-Price ''           | Should -BeNullOrEmpty
    }
    It 'extrait un prix depuis du JSON-LD' {
        ConvertFrom-ScrapedPrice -Html '..."price":"799.99","priceCurrency":"EUR"...' `
            -Pattern '"price"\s*:\s*"?(?<price>[0-9]+(?:[.,][0-9]{2})?)' | Should -Be ([decimal]799.99)
    }
    It 'renvoie null si aucun prix' {
        ConvertFrom-ScrapedPrice -Html 'rien' -Pattern '"price"\s*:\s*"?(?<price>[0-9.]+)' | Should -BeNullOrEmpty
    }
    It 'detecte une baisse' {
        $c = Compare-PriceChange -OldPrice ([decimal]799.99) -NewPrice ([decimal]699.99)
        $c.Changed | Should -BeTrue
        $c.Direction | Should -Be 'baisse'
    }
    It 'detecte une hausse' {
        (Compare-PriceChange -OldPrice ([decimal]699) -NewPrice ([decimal]749)).Direction | Should -Be 'hausse'
    }
    It 'ne signale pas le premier releve' {
        (Compare-PriceChange -OldPrice $null -NewPrice ([decimal]799)).Changed | Should -BeFalse
    }
    It 'respecte le seuil de variation' {
        (Compare-PriceChange -OldPrice ([decimal]100) -NewPrice ([decimal]101) -ThresholdPercent 2).Changed | Should -BeFalse
    }
}

Describe 'Produits suivis' {
    It 'charge la PS5 sur les trois sites' {
        $prods = Get-PromoProducts -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/products.json')
        @($prods.products.id) | Should -Contain 'ps5-pro'
        @($prods.products.id) | Should -Contain 'ps5-slim'
        $sites = @(($prods.products | Where-Object id -eq 'ps5-pro').sites.site)
        $sites | Should -Contain 'amazon-fr'
        $sites | Should -Contain 'fnac'
        $sites | Should -Contain 'carrefour'
    }
}
