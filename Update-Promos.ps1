#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Met a jour le catalogue de codes promo depuis les sources configurees.

.DESCRIPTION
    Lance la recuperation des flux declares dans config/sources.json, fusionne les
    nouveaux codes/offres dans data/promo-codes.json et horodate la mise a jour.
    Par defaut, ne fait rien si la derniere mise a jour date de moins de -IntervalDays
    jours (3 par defaut) ; utilise -Force pour ignorer ce garde-fou. Le workflow
    planifie (tous les 3 jours) appelle ce script avec -Force, la cadence etant deja
    geree par le planificateur.

.PARAMETER IntervalDays
    Intervalle minimal en jours entre deux mises a jour (defaut : 3).

.PARAMETER Force
    Force la mise a jour meme si l'intervalle n'est pas atteint.

.PARAMETER TimeoutSec
    Delai maximal par source (defaut : 20s).

.EXAMPLE
    pwsh ./Update-Promos.ps1            # respecte l'intervalle de 3 jours
    pwsh ./Update-Promos.ps1 -Force     # met a jour immediatement
#>
[CmdletBinding()]
param(
    [int]$IntervalDays = 3,
    [switch]$Force,
    [int]$TimeoutSec = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/PromoAggregator.psd1') -Force

$today = (Get-Date).Date

# Garde-fou : ne pas mettre a jour trop souvent (sauf -Force).
if (-not $Force) {
    $catalog = Get-PromoCatalog
    if ($catalog.PSObject.Properties.Name -contains 'lastUpdated' -and $catalog.lastUpdated) {
        try {
            $last = ConvertTo-PromoDate $catalog.lastUpdated
            if ($null -ne $last -and ($today - $last).TotalDays -lt $IntervalDays) {
                $next = $last.AddDays($IntervalDays)
                Write-Host ("Derniere mise a jour : {0}. Prochaine prevue le {1} (intervalle {2}j). Utilise -Force pour forcer." -f `
                        $catalog.lastUpdated, $next.ToString('yyyy-MM-dd'), $IntervalDays) -ForegroundColor Yellow
                exit 0
            }
        } catch {
            Write-Warning "Champ 'lastUpdated' illisible, mise a jour lancee : $($_.Exception.Message)"
        }
    }
}

Write-Host 'Mise a jour des codes promo depuis les sources...' -ForegroundColor Cyan
$result = Update-PromoCatalog -TimeoutSec $TimeoutSec

Write-Host ''
Write-Host ("Termine le {0} : {1} ajout(s), {2} mise(s) a jour, {3} source(s) OK, {4} echec(s)." -f `
        $result.LastUpdated, $result.Added, $result.Updated, $result.Sources, $result.Failed) -ForegroundColor Green

if ($result.Sources -eq 0 -and $result.Failed -eq 0) {
    Write-Host "Aucune source active dans config/sources.json. Ajoute une source (enabled=true) pour recuperer des codes." -ForegroundColor DarkYellow
}
