#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Planifie (ou retire) le suivi des prix en local, via le Planificateur de taches Windows.

.DESCRIPTION
    Enregistre une tache Windows qui execute Watch-Prices.ps1 a intervalle regulier,
    sans rien lancer manuellement et sans dependre de GitHub. A lancer une seule fois.
    Sur Linux/macOS, affiche l'equivalent cron a ajouter.

.PARAMETER IntervalHours
    Frequence du releve de prix, en heures (defaut : 6).

.PARAMETER TaskName
    Nom de la tache planifiee (defaut : PromoAggregator-PriceWatch).

.PARAMETER RunNow
    Execute aussi un premier releve immediatement apres l'enregistrement.

.PARAMETER Unregister
    Supprime la tache planifiee au lieu de la creer.

.EXAMPLE
    pwsh ./Register-PriceWatchTask.ps1                  # toutes les 6 h
    pwsh ./Register-PriceWatchTask.ps1 -IntervalHours 1 -RunNow
    pwsh ./Register-PriceWatchTask.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 168)][int]$IntervalHours = 6,
    [string]$TaskName = 'PromoAggregator-PriceWatch',
    [switch]$RunNow,
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$watchScript = Join-Path $root 'Watch-Prices.ps1'

if (-not $IsWindows) {
    Write-Host "Planification automatique : disponible sous Windows uniquement." -ForegroundColor Yellow
    Write-Host "Sous Linux/macOS, ajoute cette ligne a ta crontab (crontab -e) pour un releve toutes les $IntervalHours h :" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  0 */$IntervalHours * * *  pwsh -NoProfile -File '$watchScript'" -ForegroundColor Green
    Write-Host ""
    Write-Host "Ou lance simplement le suivi a la demande : pwsh '$watchScript'"
    exit 0
}

# --- Windows : Planificateur de taches ---
$pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source
if (-not $pwshPath) { $pwshPath = (Get-Process -Id $PID).Path }  # repli sur l'executable courant

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Tache '$TaskName' supprimee." -ForegroundColor Green
    } else {
        Write-Host "Aucune tache '$TaskName' a supprimer." -ForegroundColor DarkYellow
    }
    return
}

$action = New-ScheduledTaskAction -Execute $pwshPath `
    -Argument "-NoProfile -WindowStyle Hidden -File `"$watchScript`"" `
    -WorkingDirectory $root

# Declencheur : maintenant, puis repetition indefinie a l'intervalle demande.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Suivi de prix PS5 (PromoAggregator) toutes les $IntervalHours h" -Force | Out-Null

Write-Host "Tache '$TaskName' enregistree : releve les prix toutes les $IntervalHours h." -ForegroundColor Green
Write-Host "Verifier : Get-ScheduledTask -TaskName '$TaskName'   |   Supprimer : ./Register-PriceWatchTask.ps1 -Unregister" -ForegroundColor DarkGray

if ($RunNow) {
    Write-Host "`nPremier releve immediat..." -ForegroundColor Cyan
    & $watchScript
}
