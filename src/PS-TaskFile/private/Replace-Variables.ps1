function Replace-Variables {
    param(
        [string]$Command,
        [hashtable]$Variables
    )
    
    foreach ($key in $Variables.Keys) {
        $Command = $Command -replace "\`$$key", $Variables[$key]
    }
    
    return $Command
}