# PowerShell profile - versioned in dotfiles, linked to $PROFILE.CurrentUserAllHosts.
#
# AllHosts (profile.ps1, not Microsoft.PowerShell_profile.ps1) so it loads in Windows
# Terminal, the ISE and the VS Code integrated terminal alike. The same file is linked
# into both Windows PowerShell's and PowerShell 7's profile directories.
#
# This file is shared across machines, so everything in it must either be true
# everywhere or guard itself. Anything genuinely local to one machine belongs in
# profile.local.ps1, which the last block here dot-sources.

# --- completion ---------------------------------------------------------------
# Out of the box Tab is TabCompleteNext, which cycles through matches one at a time
# without showing you what they are; the menu lives on Ctrl+Space. Swap so Tab opens
# the menu - Shift+Tab still steps backwards, and inside the menu the arrow keys
# navigate.
#
# Guarded because profile.ps1 is the AllHosts profile: it also runs in hosts that
# never load PSReadLine, where these cmdlets do not exist.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# --- zoxide -------------------------------------------------------------------
# Guarded rather than unconditional. The same profile lands on every machine and
# one of them may not have zoxide yet; `bootstrap.ps1 -Modules packages` installs
# it. Until then this block is skipped instead of erroring on every new prompt.
#
# Gives you `z <partial>` to jump to a frecent directory. `zi` picks
# interactively and needs fzf, which the packages module installs alongside.
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# --- machine-local ------------------------------------------------------------
# Last, so a machine can override anything set above.
#
# profile.local.ps1 is gitignored: it holds the things that are true of one machine
# only - a path that exists nowhere else, a work-only tool's setup. Edit it in
# the repo alongside this file; `bootstrap.ps1 -Modules powershell` links it beside
# each host's profile.ps1, which is why $PSScriptRoot finds it. Machines without one
# skip this silently.
#
# Not dot-sourced from the repo directly, and not named
# Microsoft.PowerShell_profile.ps1 - see the powershell module in
# bootstrap/modules.json for why.
$localProfile = Join-Path $PSScriptRoot 'profile.local.ps1'
if (Test-Path -LiteralPath $localProfile) { . $localProfile }
