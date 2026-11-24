param([switch]$LoopbackOnly)

$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$players = @{}
$scores = @{ to = @{ t = 0; ct = 0 } }
$matchStartedAt = $null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$port = 8765

function Read-HttpRequest($stream) {
    $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
    while ($headerBytes.Count -lt 16384) {
        $nextByte = $stream.ReadByte()
        if ($nextByte -lt 0) { return $null }
        $headerBytes.Add([byte]$nextByte)
        $count = $headerBytes.Count
        if ($count -ge 4 -and $headerBytes[$count - 4] -eq 13 -and $headerBytes[$count - 3] -eq 10 -and $headerBytes[$count - 2] -eq 13 -and $headerBytes[$count - 1] -eq 10) { break }
    }
    if ($headerBytes.Count -ge 16384) { throw "Request headers are too large" }

    $lines = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray()) -split "`r`n"
    $requestLine = $lines[0] -split " ", 3
    if ($requestLine.Count -lt 2) { throw "Invalid request line" }
    $headers = @{}
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $separator = $line.IndexOf(":")
        if ($separator -gt 0) { $headers[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).Trim() }
    }
    if ($headers.ContainsKey("Transfer-Encoding")) { throw "Chunked requests are not supported" }
    $contentLength = 0
    if ($headers.ContainsKey("Content-Length") -and -not [int]::TryParse($headers["Content-Length"], [ref]$contentLength)) { throw "Invalid content length" }
    if ($contentLength -gt 65536) { throw "Request body is too large" }
    $bodyBytes = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($read -le 0) { throw "Incomplete request body" }
        $offset += $read
    }
    return [PSCustomObject]@{
        Method = $requestLine[0]
        Target = $requestLine[1]
        Body = $utf8.GetString($bodyBytes)
    }
}

function Write-Response($stream, [int]$status, [string]$reason, [string]$contentType, [byte[]]$body) {
    $header = "HTTP/1.1 $status $reason`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Write-JsonResponse($stream, [int]$status, $data) {
    $reason = switch ($status) {
        200 { "OK" }
        400 { "Bad Request" }
        401 { "Unauthorized" }
        404 { "Not Found" }
        409 { "Conflict" }
        413 { "Payload Too Large" }
        default { "Internal Server Error" }
    }
    $json = ConvertTo-Json -InputObject $data -Depth 8 -Compress
    Write-Response $stream $status $reason "application/json; charset=utf-8" $utf8.GetBytes($json)
}

function Get-Player($id, $token) {
    if (-not $id -or -not $players.ContainsKey([string]$id)) { return $null }
    $player = $players[[string]$id]
    if (-not $token -or $player.token -ne [string]$token) { return $null }
    return $player
}

function Get-Snapshot([string]$mapId) {
    $visiblePlayers = @($players.Values | Where-Object { $_.mapId -eq $mapId } | ForEach-Object {
        @{
            id = $_.id; name = $_.name; side = $_.side
            x = $_.x; y = $_.y; z = $_.z; yaw = $_.yaw; pitch = $_.pitch
            weapon = $_.weapon; health = $_.health; respawnCount = $_.respawnCount
        }
    })
    $matchRemaining = 600.0
    if ($matchStartedAt) { $matchRemaining = [Math]::Max(0, 600 - ([DateTimeOffset]::UtcNow - $matchStartedAt).TotalSeconds) }
    return @{
        players = $visiblePlayers
        scores = $scores[$mapId]
        matchRemaining = $matchRemaining
        serverTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}

function Remove-StalePlayers {
    $cutoff = [DateTimeOffset]::UtcNow.AddSeconds(-15)
    foreach ($id in @($players.Keys)) {
        if ($players[$id].lastSeen -lt $cutoff) { $players.Remove($id) }
    }
    if (@($players.Values | Where-Object { $_.mapId -eq "to" }).Count -eq 0) {
        $scores.to.t = 0
        $scores.to.ct = 0
        $script:matchStartedAt = $null
    }
}

function Convert-ToFiniteNumber($value, [string]$name) {
    $number = 0.0
    if (-not [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "Invalid $name value"
    }
    return $number
}

function Process-Request($stream, $request) {
    $target = [Uri]::UnescapeDataString(($request.Target -split "\?", 2)[0])
    if ($request.Method -eq "GET" -and $target -eq "/api/health") {
        Write-JsonResponse $stream 200 @{ online = $true }
        return
    }

    if ($target.StartsWith("/api/")) {
        if ($request.Method -ne "POST") {
            Write-JsonResponse $stream 400 @{ error = "POST is required" }
            return
        }
        $body = $null
        try { $body = ConvertFrom-Json -InputObject $request.Body }
        catch {
            Write-JsonResponse $stream 400 @{ error = "Invalid JSON request body" }
            return
        }

        if ($target -eq "/api/join") {
            Remove-StalePlayers
            if ($body.mapId -ne "to" -or $body.side -notin @("t", "ct")) {
                Write-JsonResponse $stream 400 @{ error = "Only Training Outside and the T/CT sides are supported online" }
                return
            }
            $roomCount = @($players.Values | Where-Object { $_.mapId -eq $body.mapId }).Count
            if ($roomCount -ge 12) {
                Write-JsonResponse $stream 409 @{ error = "The match is full (12 players maximum)" }
                return
            }
            $id = [Guid]::NewGuid().ToString("N")
            $token = [Guid]::NewGuid().ToString("N")
            $spawn = if ($body.side -eq "t") { @{ x = -3.5; z = -24.7 } } else { @{ x = -2.7; z = 24.2 } }
            $player = @{
                id = $id; token = $token; name = "Player $($roomCount + 1)"
                mapId = "to"; side = [string]$body.side
                x = $spawn.x; y = 0.0; z = $spawn.z; yaw = 0.0; pitch = 0.0
                weapon = "ak"; health = 100; respawnCount = 0
                respawnAt = $null; lastSeen = [DateTimeOffset]::UtcNow
                lastShot = [DateTimeOffset]::MinValue
            }
            $players[$id] = $player
            Write-JsonResponse $stream 200 (@{ id = $id; token = $token } + (Get-Snapshot "to"))
            return
        }

        $player = Get-Player $body.id $body.token
        if (-not $player) {
            Write-JsonResponse $stream 401 @{ error = "Player session expired; reconnect to the match" }
            return
        }
        $player.lastSeen = [DateTimeOffset]::UtcNow

        if ($target -eq "/api/state") {
            Remove-StalePlayers
            if (-not $players.ContainsKey($player.id)) {
                Write-JsonResponse $stream 401 @{ error = "Player session expired; reconnect to the match" }
                return
            }
            if (-not $body.state) {
                Write-JsonResponse $stream 400 @{ error = "Player state is required" }
                return
            }
            try {
                $player.x = Convert-ToFiniteNumber $body.state.x "x"
                $player.y = Convert-ToFiniteNumber $body.state.y "y"
                $player.z = Convert-ToFiniteNumber $body.state.z "z"
                $player.yaw = Convert-ToFiniteNumber $body.state.yaw "yaw"
                $player.pitch = Convert-ToFiniteNumber $body.state.pitch "pitch"
            } catch {
                Write-JsonResponse $stream 400 @{ error = $_.Exception.Message }
                return
            }
            if ($body.state.weapon -in @("ak", "glock")) { $player.weapon = [string]$body.state.weapon }
            if (-not $matchStartedAt) { $script:matchStartedAt = [DateTimeOffset]::UtcNow }
            if ($player.respawnAt -and [DateTimeOffset]::UtcNow -ge $player.respawnAt) {
                $player.health = 100
                $player.respawnAt = $null
                $player.respawnCount++
            }
            Write-JsonResponse $stream 200 (Get-Snapshot $player.mapId)
            return
        }

        if ($target -eq "/api/hit") {
            if ($matchStartedAt -and ([DateTimeOffset]::UtcNow - $matchStartedAt).TotalSeconds -ge 600) {
                Write-JsonResponse $stream 200 (Get-Snapshot $player.mapId)
                return
            }
            if (-not $body.targetId -or -not $players.ContainsKey([string]$body.targetId)) {
                Write-JsonResponse $stream 404 @{ error = "Target player is no longer connected" }
                return
            }
            $targetPlayer = $players[[string]$body.targetId]
            if ($targetPlayer.mapId -ne $player.mapId -or $targetPlayer.side -eq $player.side -or $targetPlayer.health -le 0) {
                Write-JsonResponse $stream 200 (Get-Snapshot $player.mapId)
                return
            }
            $now = [DateTimeOffset]::UtcNow
            if (($now - $player.lastShot).TotalMilliseconds -lt 80) {
                Write-JsonResponse $stream 200 (Get-Snapshot $player.mapId)
                return
            }
            $player.lastShot = $now
            $damage = switch ([string]$body.zone) {
                "head" { 100 }
                "limb" { 14 }
                "stomach" { 23 }
                default { 28 }
            }
            if ($player.weapon -eq "glock") { $damage = [Math]::Round($damage / 1.7) }
            $targetPlayer.health = [Math]::Max(0, $targetPlayer.health - $damage)
            if ($targetPlayer.health -eq 0) {
                $targetPlayer.respawnAt = $now.AddSeconds(1.5)
                $scores[$player.mapId][$player.side]++
            }
            Write-JsonResponse $stream 200 (Get-Snapshot $player.mapId)
            return
        }

        if ($target -eq "/api/leave") {
            $players.Remove($player.id)
            Remove-StalePlayers
            Write-JsonResponse $stream 200 @{ left = $true }
            return
        }
        Write-JsonResponse $stream 404 @{ error = "Unknown API endpoint" }
        return
    }

    if ($request.Method -ne "GET") {
        Write-JsonResponse $stream 404 @{ error = "Not found" }
        return
    }
    if ($target -eq "/") { $target = "/Chemk Strike.html" }
    $relativePath = $target.TrimStart("/") -replace "/", [System.IO.Path]::DirectorySeparatorChar
    $filePath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath))
    if (-not $filePath.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-JsonResponse $stream 404 @{ error = "File not found" }
        return
    }
    $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
    $contentType = switch ($extension) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".glb" { "model/gltf-binary" }
        ".png" { "image/png" }
        ".jpg" { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".jfif" { "image/jpeg" }
        ".webp" { "image/webp" }
        ".mp3" { "audio/mpeg" }
        default { "application/octet-stream" }
    }
    $file = [System.IO.File]::OpenRead($filePath)
    try {
        $header = "HTTP/1.1 200 OK`r`nContent-Type: $contentType`r`nContent-Length: $($file.Length)`r`nConnection: close`r`nCache-Control: no-cache`r`n`r`n"
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $file.CopyTo($stream)
        $stream.Flush()
    } finally { $file.Dispose() }
}

$bindAddress = if ($LoopbackOnly) { [System.Net.IPAddress]::Loopback } else { [System.Net.IPAddress]::Any }
$listener = [System.Net.Sockets.TcpListener]::new($bindAddress, $port)
try {
    $listener.Start()
    Write-Host "LAN game server started. Share one of these addresses with players:"
    if ($LoopbackOnly) { Write-Host "  http://127.0.0.1:$port/Chemk%20Strike.html" }
    $addresses = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($_.Address) -and $_.Address.ToString() -notlike "169.254.*" } |
        ForEach-Object { "http://$($_.Address):$port/Chemk%20Strike.html" } |
        Sort-Object -Unique
    if (-not $LoopbackOnly -and $addresses) { $addresses | ForEach-Object { Write-Host "  $_" } }
    elseif (-not $LoopbackOnly) { Write-Host "  Could not detect a local IP address. Check the Wi-Fi connection." }
    Write-Host "Keep this window open while playing. Press Ctrl+C to stop the server."

    while ($true) {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 30000
        $stream = $client.GetStream()
        try {
            $request = Read-HttpRequest $stream
            if ($request) { Process-Request $stream $request }
        } catch {
            Write-Host "Rejected request: $($_.Exception.Message)"
            $errorBody = @{ error = 'Invalid request' }
            Write-JsonResponse -stream $stream -status 400 -data $errorBody
        } finally {
            $stream.Dispose()
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
