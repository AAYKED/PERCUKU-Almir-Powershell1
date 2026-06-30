#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Suit le prix des produits (PS5 Pro / Slim) et alerte en cas de baisse ou de hausse.

.DESCRIPTION
    Releve le prix de chaque produit de config/products.json sur chaque site active,
    le compare au dernier prix connu (data/price-history.json) et notifie toute
    variation (console, fichier d'alertes, webhook et notification locale si configures).

.PARAMETER TimeoutSec
    Delai maximal par page (defaut : 20s).

.PARAMETER NoAlert
    Met a jour l'historique sans envoyer d'alerte (utile pour initialiser les prix de base).

.EXAMPLE
    pwsh ./Watch-Prices.ps1
    pwsh ./Watch-Prices.ps1 -NoAlert   # initialise les prix de reference sans alerter
#>
[CmdletBinding()]
param(
    [int]$TimeoutSec = 20,
    [switch]$NoAlert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/PromoAggregator.psd1') -Force

Write-Host '==== Suivi des prix ====' -ForegroundColor Cyan
$result = Update-PriceWatch -TimeoutSec $TimeoutSec -NoAlert:$NoAlert

Write-Host ''
Write-Host ("Prix releves : {0} | Alertes : {1} | Echecs : {2}" -f `
        $result.Checked, @($result.Alerts).Count, $result.Failed) -ForegroundColor Cyan

if (@($result.Alerts).Count -eq 0) {
    if ($result.Checked -eq 0) {
        Write-Host "Aucun prix relevé. Verifie les URLs/pricePattern dans config/products.json (remplace les valeurs 'REMPLACER-...')." -ForegroundColor DarkYellow
    } else {
        Write-Host "Aucune variation de prix detectee." -ForegroundColor DarkGray
    }
}
