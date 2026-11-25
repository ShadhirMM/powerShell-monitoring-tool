@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Tests and helpers legitimately use these patterns.
        'PSUseShouldProcessForStateChangingFunctions'   # New-FW* only build objects in memory; they change no system state
    )
}
