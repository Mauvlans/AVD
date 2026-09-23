@{
    # Analyzer config for the AVD/W365 redirection scripts.
    # Every exclusion is a reviewed decision with a reason, not unexplained debt.
    # DO NOT exclude PSShouldProcess - it catches genuine dynamic-scoping defects.
    ExcludeRules = @(
        # Coloured console output IS the interface for these operator-facing scripts.
        # Write-Output would break the formatting and pollute the pipeline.
        'PSAvoidUsingWriteHost',

        # Best-effort side reads (optional registry keys, event logs that may be
        # disabled, frx.exe that may not exist) must stay silent. A diagnostic script
        # runs precisely when things are already broken; a throw there loses the whole
        # report for the sake of one absent optional value.
        'PSAvoidUsingEmptyCatchBlock',

        # Set-HostPoolRedirection / Set-IntuneRedirectionPolicy deliberately do NOT
        # implement ShouldProcess. Gating is Confirm-Change (explicit per-change y/N
        # showing BEFORE -> AFTER) plus the -DryRun switch. Adding
        # SupportsShouldProcess without calling ShouldProcess is strictly worse than
        # omitting it: PSShouldProcess flags it, and it advertises a -WhatIf that does
        # nothing. Revisit only if the functions are ever refactored to call
        # $PSCmdlet.ShouldProcess for real.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
