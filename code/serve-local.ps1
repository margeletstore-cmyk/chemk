$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

$portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

$contentTypes = @{
    ".glb"  = "model/gltf-binary"
    ".html" = "text/html; charset=utf-8"
    ".jfif" = "image/jpeg"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".js"   = "application/javascript"
    ".mp3"  = "audio/mpeg"
    ".png"  = "image/png"
    ".svg"  = "image/svg+xml"
    ".webp" = "image/webp"
    ".woff" = "font/woff"
    ".woff2" = "font/woff2"
}

$url = "http://127.0.0.1:$port/code/Chemk%20Strike.html"
Write-Host "Serving project at:"
Write-Host $url
Write-Host "Open this address in your preferred browser."
Write-Host "Keep this window open while playing. Press Ctrl+C to stop the server."

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response

        try {
            if ($context.Request.HttpMethod -ne "GET" -and $context.Request.HttpMethod -ne "HEAD") {
                $response.StatusCode = 405
            }
            else {
                $relativePath = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart("/"))
                if ([string]::IsNullOrEmpty($relativePath)) {
                    $relativePath = "code/Chemk Strike.html"
                }

                $filePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relativePath))
                if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $response.StatusCode = 403
                }
                elseif (-not [System.IO.File]::Exists($filePath)) {
                    $response.StatusCode = 404
                }
                else {
                    $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                    if ($contentTypes.ContainsKey($extension)) {
                        $response.ContentType = $contentTypes[$extension]
                    }
                    else {
                        $response.ContentType = "application/octet-stream"
                    }

                    $file = [System.IO.File]::OpenRead($filePath)
                    try {
                        $response.ContentLength64 = $file.Length
                        if ($context.Request.HttpMethod -eq "GET") {
                            $file.CopyTo($response.OutputStream)
                        }
                    }
                    finally {
                        $file.Dispose()
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to serve $($context.Request.RawUrl): $($_.Exception.Message)"
            $response.StatusCode = 500
        }
        finally {
            $response.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
