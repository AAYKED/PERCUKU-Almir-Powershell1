@{
    RootModule        = 'PromoAggregator.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b6f1a2d4-3c7e-4f0a-9b2d-1a2c3d4e5f60'
    Author            = 'PERCUKU Almir'
    Description       = 'Agregateur de codes promo multi-sites : codes valides uniquement, filtre pays (monde entier / Chine), meilleures offres en repli, catalogue editable.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-PromoConfig', 'Get-PromoCatalogPath', 'Get-PromoCatalog', 'Save-PromoCatalog',
        'Test-PromoCodeActive', 'Test-SiteMatchesCountry', 'Test-CountryCode', 'ConvertTo-PromoDate',
        'Find-PromoCode', 'Add-PromoSite', 'Add-PromoCode', 'Set-PromoCode', 'Remove-PromoCode',
        'Get-PromoSources', 'Merge-PromoCatalog', 'Update-PromoCatalog',
        'Get-PromoScrapers', 'ConvertFrom-ScrapedHtml', 'Invoke-PromoScraper', 'Add-PromoScraper'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('promo', 'codes', 'coupons', 'aggregator', 'shopping')
            ProjectUri   = 'https://github.com/aayked/percuku-almir-powershell1'
        }
    }
}
