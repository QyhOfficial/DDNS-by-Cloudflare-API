# IPv6 DDNS Update Script - Cloudflare
param(
    [string]$ApiToken = $env:CLOUDFLARE_API_TOKEN,
    [string]$RootDomain = $env:CLOUDFLARE_ZONE_NAME,
    [string]$RecordName = "omen"
)

if (-not $ApiToken) {
    Write-Host "Error: CLOUDFLARE_API_TOKEN environment variable is not set" -ForegroundColor Red
    exit 1
}
if (-not $RootDomain) {
    Write-Host "Error: CLOUDFLARE_ZONE_NAME environment variable is not set" -ForegroundColor Red
    exit 1
}

# Build full domain name
$FullDomain = if ($RecordName -like "*.$RootDomain") {
    $RecordName
} elseif ($RecordName -eq "@" -or [string]::IsNullOrWhiteSpace($RecordName)) {
    $RootDomain
} else {
    "$RecordName.$RootDomain"
}

function Get-PublicIPv6 {
    try {
        # Get IPv6 address via ipconfig
        $ipconfigOutput = ipconfig

        # Find IPv6 address lines (supports both Chinese and English Windows)
        $ipv6Lines = $ipconfigOutput | Where-Object {
            $_ -match "IPv6 地址|IPv6 Address" -and
            $_ -notmatch "本地链接|Link-local|临时|Temporary"
        }

        if ($ipv6Lines) {
            foreach ($line in $ipv6Lines) {
                # Extract IPv6 address (handle different formats)
                if ($line -match ": (.+)") {
                    $rawIPv6 = $matches[1].Trim()

                    # Clean address format (remove %interface-id, (Preferred) markers, etc.)
                    $ipv6 = ($rawIPv6 -split '%')[0] -replace '\(.*\)', ''
                    $ipv6 = $ipv6.Trim()

                    # Validate as a public IPv6 address
                    if ($ipv6 -match "^[0-9a-fA-F:]+$" -and
                        $ipv6 -notlike "fe80:*" -and
                        $ipv6 -notlike "::1" -and
                        $ipv6 -notlike "fd*" -and
                        $ipv6 -notlike "fc*" -and
                        ($ipv6 -like "2*" -or $ipv6 -like "3*")) {

                        Write-Host "Found IPv6 address via ipconfig: $ipv6" -ForegroundColor Cyan
                        return $ipv6
                    }
                }
            }
        }

        Write-Warning "No valid public IPv6 address found"
        Write-Host "Hint: Please verify that your network adapter has an IPv6 address" -ForegroundColor Yellow
        return $null
    }
    catch {
        Write-Warning "Failed to get local IPv6 address: $($_.Exception.Message)"
        return $null
    }
}

function Get-ZoneId {
    param([string]$Domain)

    $headers = @{
        "Authorization" = "Bearer $ApiToken"
        "Content-Type" = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=$Domain" -Method GET -Headers $headers

        if ($response.success -and $response.result.Count -gt 0) {
            $zoneId = $response.result[0].id
            Write-Host "Found Zone ID: $zoneId (domain: $Domain)" -ForegroundColor Cyan
            return $zoneId
        } else {
            Write-Host "Domain not found: $Domain" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host "Failed to get Zone ID: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-DNSRecordId {
    param(
        [string]$ZoneId,
        [string]$FullDomain
    )

    $headers = @{
        "Authorization" = "Bearer $ApiToken"
        "Content-Type" = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records?type=AAAA&name=$FullDomain" -Method GET -Headers $headers

        if ($response.success -and $response.result.Count -gt 0) {
            $recordId = $response.result[0].id
            $currentIP = $response.result[0].content
            Write-Host "Found DNS record ID: $recordId (current IP: $currentIP)" -ForegroundColor Cyan
            return @{
                RecordId = $recordId
                CurrentIP = $currentIP
            }
        } else {
            Write-Host "DNS record not found: $FullDomain (AAAA type)" -ForegroundColor Yellow
            return $null
        }
    }
    catch {
        Write-Host "Failed to get DNS record: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function New-CloudflareDNS {
    param(
        [string]$ZoneId,
        [string]$IPv6Address
    )

    $headers = @{
        "Authorization" = "Bearer $ApiToken"
        "Content-Type" = "application/json"
    }

    $body = @{
        type = "AAAA"
        name = $FullDomain
        content = $IPv6Address
        ttl = 1
        proxied = $false
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records" -Method POST -Headers $headers -Body $body

        if ($response.success) {
            Write-Host "DNS record created successfully: $FullDomain -> $IPv6Address" -ForegroundColor Green
            return $true
        } else {
            Write-Host "DNS creation failed: $($response.errors | ConvertTo-Json)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "API call failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Update-CloudflareDNS {
    param(
        [string]$ZoneId,
        [string]$RecordId,
        [string]$IPv6Address
    )

    $headers = @{
        "Authorization" = "Bearer $ApiToken"
        "Content-Type" = "application/json"
    }

    $body = @{
        type = "AAAA"
        name = $FullDomain
        content = $IPv6Address
        ttl = 1
        proxied = $false
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$RecordId" -Method PUT -Headers $headers -Body $body

        if ($response.success) {
            Write-Host "DNS record updated successfully: $FullDomain -> $IPv6Address" -ForegroundColor Green
            return $true
        } else {
            Write-Host "DNS update failed: $($response.errors | ConvertTo-Json)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "API call failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Main
Write-Host "====== Starting IPv6 DDNS update check ======" -ForegroundColor Cyan
Write-Host "Record name: $RecordName -> Full domain: $FullDomain" -ForegroundColor Cyan

# Get current IPv6 address
$currentIPv6 = Get-PublicIPv6
if (-not $currentIPv6) {
    Write-Host "Failed to get IPv6 address, exiting" -ForegroundColor Red
    exit 1
}

# Get Zone ID
$zoneId = Get-ZoneId -Domain $RootDomain
if (-not $zoneId) {
    Write-Host "Failed to get Zone ID, exiting" -ForegroundColor Red
    exit 1
}

# Get DNS record ID and current IP
$dnsInfo = Get-DNSRecordId -ZoneId $zoneId -FullDomain $FullDomain

if (-not $dnsInfo) {
    Write-Host "DNS record does not exist, creating new record..." -ForegroundColor Yellow
    $success = New-CloudflareDNS -ZoneId $zoneId -IPv6Address $currentIPv6
} else {
    $recordId = $dnsInfo.RecordId
    $dnsIPv6 = $dnsInfo.CurrentIP

    Write-Host "Current DNS record: $dnsIPv6" -ForegroundColor Cyan

    if ($dnsIPv6 -eq $currentIPv6) {
        Write-Host "IP address unchanged, no update needed" -ForegroundColor Cyan
        exit 0
    }

    Write-Host "IP address changed: $dnsIPv6 -> $currentIPv6" -ForegroundColor Yellow
    $success = Update-CloudflareDNS -ZoneId $zoneId -RecordId $recordId -IPv6Address $currentIPv6
}

if ($success) {
    Write-Host "====== IPv6 DDNS update completed ======" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "====== IPv6 DDNS update failed ======" -ForegroundColor Red
    exit 1
}
