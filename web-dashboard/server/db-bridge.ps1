# =====================================================================
#  db-bridge.ps1  -  jembatan Node.js <-> SQL Server (Windows Authentication)
#  Membaca 1 permintaan JSON per baris dari stdin:
#     {"id":1,"sql":"SELECT ... WHERE x=@a","params":{"a":123}}
#  dan menulis 1 baris JSON hasil ke stdout:
#     {"id":1,"ok":true,"sets":[[{...},{...}], [...]]}
#  Memakai System.Data.SqlClient bawaan .NET Framework, jadi tidak perlu
#  driver tambahan dan tidak perlu username/password SQL.
# =====================================================================
param([Parameter(Mandatory = $true)][string]$ConnStr)

$ErrorActionPreference = 'Stop'
$utf8   = New-Object System.Text.UTF8Encoding $false
$stdin  = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true
Add-Type -AssemblyName System.Data

$conn = New-Object System.Data.SqlClient.SqlConnection $ConnStr

function Open-Conn {
    if ($conn.State -ne [System.Data.ConnectionState]::Open) {
        try { $conn.Close() } catch {}
        $conn.Open()
    }
}

$stdout.WriteLine('{"id":0,"ok":true,"ready":true}')

while ($true) {
    $line = $stdin.ReadLine()
    if ($null -eq $line) { break }
    if ($line.Trim() -eq '') { continue }
    $id = 0
    $rd = $null
    try {
        $req = $line | ConvertFrom-Json
        $id = $req.id
        Open-Conn
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = [string]$req.sql
        $cmd.CommandTimeout = 120
        if ($null -ne $req.params) {
            foreach ($p in $req.params.PSObject.Properties) {
                $v = $p.Value
                if ($null -eq $v) { $v = [DBNull]::Value }
                [void]$cmd.Parameters.AddWithValue('@' + $p.Name, $v)
            }
        }
        $rd = $cmd.ExecuteReader()
        $sets = New-Object System.Collections.ArrayList
        do {
            $rows = New-Object System.Collections.ArrayList
            while ($rd.Read()) {
                $o = [ordered]@{}
                for ($i = 0; $i -lt $rd.FieldCount; $i++) {
                    $v = $rd.GetValue($i)
                    if ($v -is [DBNull])        { $v = $null }
                    elseif ($v -is [datetime])  { $v = $v.ToString('yyyy-MM-ddTHH:mm:ss') }
                    elseif ($v -is [decimal])   { $v = [double]$v }
                    elseif ($v -is [single])    { $v = [double]$v }
                    elseif ($v -is [byte] -or $v -is [int16]) { $v = [int]$v }
                    $o[$rd.GetName($i)] = $v
                }
                [void]$rows.Add([pscustomobject]$o)
            }
            [void]$sets.Add($rows)
        } while ($rd.NextResult())
        $rd.Close()
        $out = [ordered]@{ id = $id; ok = $true; sets = $sets }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $msg + ' | ' + $_.Exception.InnerException.Message }
        $out = [ordered]@{ id = $id; ok = $false; error = $msg }
        try { if ($rd -and -not $rd.IsClosed) { $rd.Close() } } catch {}
    }
    $json = ConvertTo-Json -InputObject $out -Depth 8 -Compress
    $stdout.WriteLine($json)
}
