# PowerShell profile - versioned in dotfiles, linked to $PROFILE.CurrentUserAllHosts.
#
# AllHosts (profile.ps1, not Microsoft.PowerShell_profile.ps1) so it loads in Windows
# Terminal, the ISE and the VS Code integrated terminal alike.
#
# This file is shared across machines, so everything in it must either be true
# everywhere or guard itself. Anything genuinely local to one machine belongs in
# Microsoft.PowerShell_profile.ps1 next to this file, which is deliberately not
# versioned - PowerShell loads both, AllHosts first.

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
