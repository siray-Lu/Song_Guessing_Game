$root = $PSScriptRoot
$port = 8794

# 先只用 localhost 啟動，這組一定要成功
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "Serving $root"
foreach ($p in $listener.Prefixes) { Write-Host "  $p" }

# 啟動成功後，再嘗試「動態」加上區網位址；就算這段失敗也不影響上面已經在跑的 listener
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -First 1).IPAddress
if ($lanIp) {
    try {
        $listener.Prefixes.Add("http://${lanIp}:$port/")
        Write-Host "  http://${lanIp}:$port/ (LAN)"
    } catch {
        Write-Host "LAN bind failed ($($_.Exception.Message)) - only localhost is reachable"
    }
}

$mime = @{ ".html"="text/html"; ".js"="application/javascript"; ".css"="text/css"; ".json"="application/json" }

# ===================== Multiplayer room state (in-memory) =====================
$rooms = @{}

# Drop players that stopped polling. Browsers throttle timers in background tabs
# (Chrome slows them to once a minute), so keep this generous or we kick real players.
$GHOST_MS = 60000

function Remove-GhostPlayers {
    param($room)
    $now = Now-Ms
    $ids = @($room.players.Keys)
    if ($ids.Count -le 1) { return }
    $removed = $false
    foreach ($id in $ids) {
        $p = $room.players[$id]
        if ($p.lastSeen -and (($now - $p.lastSeen) -gt $GHOST_MS)) {
            $room.players.Remove($id)
            if ($room.answers.ContainsKey($id)) { $room.answers.Remove($id) }
            $removed = $true
        }
    }
    if ($removed -and -not $room.players.ContainsKey($room.hostPlayerId)) {
        $first = @($room.players.Keys)[0]
        if ($first) { $room.hostPlayerId = $first }
    }
}

function Touch-Player {
    param($room, $playerId)
    if ($playerId -and $room.players.ContainsKey($playerId)) {
        $room.players[$playerId].lastSeen = (Now-Ms)
    }
}

function New-RoomCode {
    do {
        $code = -join ((0..9) | Get-Random -Count 4)
    } while ($rooms.ContainsKey($code))
    return $code
}

function Now-Ms {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

$MAX_PLAYERS = 8

function Advance-RoomPhase($room) {
    $now = Now-Ms
    $elapsed = $now - $room.phaseStartedAt
    switch ($room.phase) {
        'countdown' {
            if ($elapsed -ge 3000) {
                $room.phase = 'playing'
                $room.phaseStartedAt = $now
                $room.answers = @{}
            }
        }
        'playing' {
            # 搶答制：只要有人答對就立刻公布，不用等全部人都作答完
            $anyCorrect = $false
            foreach ($playerKey in $room.answers.Keys) {
                if ($room.answers[$playerKey].correct) { $anyCorrect = $true; break }
            }
            $allAnswered = $room.answers.Count -ge $room.players.Count
            $clipMs = ([int]$room.clipSeconds[$room.index]) * 1000 + 3000
            if ($anyCorrect -or $allAnswered -or $elapsed -ge $clipMs) {
                $winnerId = $null
                $bestMs = [double]::MaxValue
                foreach ($playerKey in $room.answers.Keys) {
                    $a = $room.answers[$playerKey]
                    if ($a.correct -and $a.atMs -lt $bestMs) {
                        $bestMs = $a.atMs
                        $winnerId = $playerKey
                    }
                }
                if ($winnerId -and $room.players.ContainsKey($winnerId)) {
                    $room.players[$winnerId].score++
                }
                $room.lastRoundWinnerId = $winnerId

                $room.phase = 'revealed'
                $room.phaseStartedAt = $now
            }
        }
        'revealed' {
            if ($elapsed -ge 4000) {
                if ($room.index -ge ($room.songIds.Count - 1)) {
                    $room.phase = 'finished'
                } else {
                    $room.index++
                    $room.phase = 'countdown'
                    $room.phaseStartedAt = $now
                    $room.answers = @{}
                }
            }
        }
    }
}

function Room-PublicState($room) {
    $playersOut = @($room.players.Keys | ForEach-Object {
        $playerKey = $_
        $p = $room.players[$playerKey]
        @{ id = $playerKey; name = $p.name; score = $p.score; answered = $room.answers.ContainsKey($playerKey) }
    })
    $winnerName = $null
    if ($room.lastRoundWinnerId -and $room.players.ContainsKey($room.lastRoundWinnerId)) {
        $winnerName = $room.players[$room.lastRoundWinnerId].name
    }
    return @{
        ok = $true
        code = $room.code
        phase = $room.phase
        index = $room.index
        total = $room.songIds.Count
        correctSongId = $room.songIds[$room.index]
        clipSeconds = $room.clipSeconds[$room.index]
        start = $room.starts[$room.index]
        phaseStartedAt = $room.phaseStartedAt
        serverNow = (Now-Ms)
        hostPlayerId = $room.hostPlayerId
        players = $playersOut
        lastRoundWinnerId = $room.lastRoundWinnerId
        lastRoundWinnerName = $winnerName
        chat = @($room.chat)
    }
}

function Read-JsonBody($req) {
    # $req.ContentEncoding 在沒有 charset 的 Content-Type 下會退回系統 ANSI 內碼頁，
    # 但瀏覽器 fetch() 一律是送 UTF-8 位元組，兩者不一致會讓中文變亂碼，所以這裡強制用 UTF8 解碼
    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Write-JsonResponse($res, $obj, $statusCode = 200) {
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $statusCode
    $res.ContentType = "application/json; charset=utf-8"
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
    } catch {
        Write-Host "GetContext failed: $($_.Exception.Message)"
        continue
    }
    $req = $context.Request
    $res = $context.Response
    $path = $req.Url.LocalPath
    $method = $req.HttpMethod

    try {
        if ($path -eq "/api/create-room" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = New-RoomCode
            $playerId = [guid]::NewGuid().ToString('N').Substring(0,8)
            $name = [string]$body.name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Player1' }
            $room = @{
                code = $code
                hostPlayerId = $playerId
                players = @{ $playerId = @{ name = $name; score = 0; lastSeen = (Now-Ms) } }
                nextPlayerNum = 2
                diffKey = $null
                songIds = @()
                clipSeconds = @()
                starts = @()
                index = 0
                phase = 'lobby'
                phaseStartedAt = (Now-Ms)
                answers = @{}
                lastRoundWinnerId = $null
                chat = @()
                chatSeq = 0
            }
            $rooms[$code] = $room
            Write-JsonResponse $res @{ ok = $true; code = $code; playerId = $playerId; name = $name }
        }
        elseif ($path -eq "/api/join-room" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = [string]$body.code
            if (-not $rooms.ContainsKey($code)) {
                Write-JsonResponse $res @{ ok = $false; error = 'room not found' } 404
            } else {
                $room = $rooms[$code]
                Remove-GhostPlayers $room
                $rejoinId = [string]$body.rejoinId
                if ($rejoinId -and $room.players.ContainsKey($rejoinId)) {
                    # Same person reconnecting - reuse their slot instead of adding a duplicate.
                    $nm = [string]$body.name
                    if (-not [string]::IsNullOrWhiteSpace($nm)) { $room.players[$rejoinId].name = $nm }
                    $room.players[$rejoinId].lastSeen = (Now-Ms)
                    Write-JsonResponse $res @{ ok = $true; playerId = $rejoinId; name = $room.players[$rejoinId].name; rejoined = $true }
                } elseif ($room.phase -ne 'lobby') {
                    Write-JsonResponse $res @{ ok = $false; error = 'already started' } 409
                } elseif ($room.players.Count -ge $MAX_PLAYERS) {
                    Write-JsonResponse $res @{ ok = $false; error = 'room full' } 409
                } else {
                    $playerId = [guid]::NewGuid().ToString('N').Substring(0,8)
                    $name = [string]$body.name
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = "Player$($room.nextPlayerNum)" }
                    $room.nextPlayerNum++
                    $room.players[$playerId] = @{ name = $name; score = 0; lastSeen = (Now-Ms) }
                    Write-JsonResponse $res @{ ok = $true; playerId = $playerId; name = $name }
                }
            }
        }
        elseif ($path -eq "/api/start-game" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = [string]$body.code
            if (-not $rooms.ContainsKey($code)) {
                Write-JsonResponse $res @{ ok = $false; error = 'room not found' } 404
            } else {
                $room = $rooms[$code]
                if ([string]$body.playerId -ne $room.hostPlayerId) {
                    Write-JsonResponse $res @{ ok = $false; error = 'only host can start' } 403
                } elseif ($room.players.Count -lt 2) {
                    Write-JsonResponse $res @{ ok = $false; error = 'need at least 2 players' } 409
                } elseif ($room.phase -ne 'lobby') {
                    Write-JsonResponse $res (Room-PublicState $room)
                } else {
                    $room.diffKey = $body.diffKey
                    $room.songIds = @($body.songIds)
                    $room.clipSeconds = @($body.clipSeconds)
                    $room.starts = @($body.starts)
                    $room.index = 0
                    $room.phase = 'countdown'
                    $room.phaseStartedAt = (Now-Ms)
                    $room.answers = @{}
                    Write-JsonResponse $res (Room-PublicState $room)
                }
            }
        }
        elseif ($path -eq "/api/room-state" -and $method -eq "GET") {
            $code = $req.QueryString["code"]
            if (-not $rooms.ContainsKey($code)) {
                Write-JsonResponse $res @{ ok = $false; error = 'room not found' } 404
            } else {
                # Every poll doubles as an "I am still here" heartbeat.
                Touch-Player $rooms[$code] ([string]$req.QueryString["playerId"])
                Remove-GhostPlayers $rooms[$code]
                Advance-RoomPhase $rooms[$code]
                Write-JsonResponse $res (Room-PublicState $rooms[$code])
            }
        }
        elseif ($path -eq "/api/submit-answer" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = [string]$body.code
            $playerId = [string]$body.playerId
            if (-not $rooms.ContainsKey($code)) {
                Write-JsonResponse $res @{ ok = $false; error = 'room not found' } 404
            } else {
                $room = $rooms[$code]
                Touch-Player $room $playerId
                Advance-RoomPhase $room
                if ($room.phase -eq 'playing' -and $room.players.ContainsKey($playerId) -and -not $room.answers.ContainsKey($playerId)) {
                    $atMs = (Now-Ms) - $room.phaseStartedAt
                    $correct = ([string]$body.songId -eq [string]$room.songIds[$room.index])
                    $room.answers[$playerId] = @{ songId = $body.songId; atMs = $atMs; correct = $correct }
                    Advance-RoomPhase $room
                }
                Write-JsonResponse $res (Room-PublicState $room)
            }
        }
        elseif ($path -eq "/api/return-to-lobby" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = [string]$body.code
            if (-not $rooms.ContainsKey($code)) {
                Write-JsonResponse $res @{ ok = $false; error = 'room not found' } 404
            } else {
                $room = $rooms[$code]
                # Only allow a reset once the previous game is over. Otherwise someone still
                # sitting on the old result screen can wipe the game everyone else is playing.
                if ($room.phase -eq 'finished') {
                    $room.phase = 'lobby'
                    $room.phaseStartedAt = (Now-Ms)
                    $room.index = 0
                    $room.songIds = @()
                    $room.clipSeconds = @()
                    $room.starts = @()
                    $room.answers = @{}
                    $room.lastRoundWinnerId = $null
                    foreach ($playerKey in @($room.players.Keys)) { $room.players[$playerKey].score = 0 }
                }
                Write-JsonResponse $res (Room-PublicState $room)
            }
        }
        elseif ($path -eq "/api/send-chat" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = [string]$body.code
            $playerId = [string]$body.playerId
            if (-not $rooms.ContainsKey($code)) {
                Write-JsonResponse $res @{ ok = $false; error = 'room not found' } 404
            } else {
                $room = $rooms[$code]
                if (-not $room.players.ContainsKey($playerId)) {
                    Write-JsonResponse $res @{ ok = $false; error = 'not in room' } 403
                } else {
                    $text = [string]$body.text
                    if ($text) { $text = $text.Trim() }
                    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
                    if ($text.Length -gt 0) {
                        $room.chatSeq++
                        $msg = @{ id = $room.chatSeq; playerId = $playerId; name = $room.players[$playerId].name; text = $text; ts = (Now-Ms) }
                        $room.chat = @($room.chat) + @($msg)
                        if ($room.chat.Count -gt 50) {
                            $room.chat = @($room.chat[($room.chat.Count - 50)..($room.chat.Count - 1)])
                        }
                    }
                    Write-JsonResponse $res @{ ok = $true }
                }
            }
        }
        elseif ($path -eq "/api/leave-room" -and $method -eq "POST") {
            $body = Read-JsonBody $req
            $code = [string]$body.code
            $playerId = [string]$body.playerId
            if ($rooms.ContainsKey($code)) {
                $room = $rooms[$code]
                if ($room.players.ContainsKey($playerId)) { $room.players.Remove($playerId) }
                # Drop their answer too, otherwise "has everyone answered" counts a ghost vote.
                if ($room.answers.ContainsKey($playerId)) { $room.answers.Remove($playerId) }
                if ($room.players.Count -eq 0) {
                    $rooms.Remove($code)
                } elseif ($room.hostPlayerId -eq $playerId) {
                    $room.hostPlayerId = @($room.players.Keys)[0]
                }
            }
            Write-JsonResponse $res @{ ok = $true }
        }
        elseif ($path -eq "/api/server-info" -and $method -eq "GET") {
            Write-JsonResponse $res @{ ok = $true; lanIp = $lanIp; port = $port }
        }
        elseif ($path -like "/api/*") {
            Write-JsonResponse $res @{ ok = $false; error = 'not found' } 404
        }
        else {
            if ($path -eq "/") { $path = "/index.html" }
            $filePath = Join-Path $root ($path.TrimStart('/'))
            if (Test-Path $filePath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($filePath)
                $ct = $mime[$ext]
                if (-not $ct) { $ct = "application/octet-stream" }
                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                $res.ContentType = $ct
                $res.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")
                $res.Headers.Add("Pragma", "no-cache")
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $res.StatusCode = 404
            }
        }
    } catch {
        try {
            Write-JsonResponse $res @{ ok = $false; error = $_.Exception.Message } 500
        } catch {}
    }
    $res.OutputStream.Close()
}
