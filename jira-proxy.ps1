param(
  [string]$ConfigPath = ".\jira-proxy.config.json",
  [string]$PatToken = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PidFile = Join-Path -Path $PSScriptRoot -ChildPath "jira-helper.pid"

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Set-CorsHeaders {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [Parameter(Mandatory = $true)]$Response,
    [string]$Methods = "GET, POST, OPTIONS"
  )

  $Response.Headers["Access-Control-Allow-Origin"] = "*"
  $requestHeaders = [string]$Context.Request.Headers["Access-Control-Request-Headers"]
  if ($requestHeaders) {
    $Response.Headers["Access-Control-Allow-Headers"] = $requestHeaders
  }
  else {
    $Response.Headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
  }
  $Response.Headers["Access-Control-Allow-Methods"] = $Methods
  if ([string]$Context.Request.Headers["Access-Control-Request-Private-Network"] -eq "true") {
    $Response.Headers["Access-Control-Allow-Private-Network"] = "true"
  }
}

function Write-JsonResponse {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode = 200,
    [Parameter(Mandatory = $true)]$Payload
  )

  $response = $Context.Response
  $response.StatusCode = $StatusCode
  $response.ContentType = "application/json; charset=utf-8"
  Set-CorsHeaders -Context $Context -Response $response

  $json = $Payload | ConvertTo-Json -Depth 8
  $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
  $response.ContentLength64 = $buffer.Length
  $response.OutputStream.Write($buffer, 0, $buffer.Length)
  $response.OutputStream.Close()
}

function Write-TextResponse {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode = 200,
    [string]$ContentType = "text/plain; charset=utf-8",
    [AllowEmptyString()]
    [Parameter(Mandatory = $true)][string]$Body
  )

  $response = $Context.Response
  $response.StatusCode = $StatusCode
  $response.ContentType = $ContentType
  Set-CorsHeaders -Context $Context -Response $response
  $response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
  $response.Headers["Pragma"] = "no-cache"

  $buffer = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $response.ContentLength64 = $buffer.Length
  $response.OutputStream.Write($buffer, 0, $buffer.Length)
  $response.OutputStream.Close()
}

function Get-StaticContentType {
  param([string]$Path)
  switch -Regex ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    "\.html$" { return "text/html; charset=utf-8" }
    "\.css$" { return "text/css; charset=utf-8" }
    "\.js$" { return "application/javascript; charset=utf-8" }
    "\.json$" { return "application/json; charset=utf-8" }
    "\.svg$" { return "image/svg+xml" }
    "\.png$" { return "image/png" }
    "\.jpe?g$" { return "image/jpeg" }
    "\.gif$" { return "image/gif" }
    "\.webp$" { return "image/webp" }
    "\.ico$" { return "image/x-icon" }
    default { return "application/octet-stream" }
  }
}

function Write-FileResponse {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $response = $Context.Response
  $response.StatusCode = 200
  $response.ContentType = Get-StaticContentType -Path $Path
  Set-CorsHeaders -Context $Context -Response $response
  $response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
  $response.Headers["Pragma"] = "no-cache"

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $response.ContentLength64 = $bytes.Length
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
  $response.OutputStream.Close()
}

function Resolve-StaticPath {
  param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][string]$RootPath
  )

  $relative = switch ($RequestPath) {
    "/" { "index.html"; break }
    "/app" { "index.html"; break }
    "/app/" { "index.html"; break }
    default {
      $trimmed = $RequestPath.TrimStart("/")
      if ($trimmed -like "assets/*") { $trimmed } else { return $null }
    }
  }

  $combined = Join-Path -Path $RootPath -ChildPath $relative
  $resolved = [System.IO.Path]::GetFullPath($combined)
  $rootResolved = [System.IO.Path]::GetFullPath($RootPath)
  if (-not $resolved.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }
  return $resolved
}

function Get-XmlUrls {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey
  )

  $trimmed = $BaseUrl.TrimEnd("/")
  return @(
    "$trimmed/si/jira.issueviews:issue-xml/$IssueKey/$IssueKey.xml",
    "$trimmed/si/jira.issueviews:issue-xml/$IssueKey/$IssueKey.xml?tempMax=1000",
    "$trimmed/secure/IssueNavigator.jspa?reset=true&jqlQuery=key%20%3D%20$IssueKey&tempMax=1000&os_authType=basic"
  )
}

function Get-IssueXml {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/xml, text/xml, */*"
  }

  $errors = @()
  foreach ($url in (Get-XmlUrls -BaseUrl $BaseUrl -IssueKey $IssueKey)) {
    try {
      $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing
      if ($response.Content -and $response.Content -match "<rss\b") {
        return @{
          Url = $url
          Xml = $response.Content
        }
      }
      $errors += "Tried $url but it did not return Jira XML."
    }
    catch {
      $errors += "Tried $url and got: $($_.Exception.Message)"
    }
  }

  throw "Could not fetch Jira XML for $IssueKey. " + ($errors -join " ")
}

function Get-IssueComments {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $trimmed = $BaseUrl.TrimEnd("/")
  $url = "$trimmed/rest/api/2/issue/$IssueKey/comment?expand=renderedBody"
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
  }

  try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    $comments = @()
    if ($response -and $response.comments) {
      $comments = @($response.comments | ForEach-Object {
        [pscustomobject]@{
          author = if ($_.author -and $_.author.displayName) { [string]$_.author.displayName } elseif ($_.author -and $_.author.name) { [string]$_.author.name } elseif ($_.author -and $_.author.key) { [string]$_.author.key } else { "Unknown" }
          authorId = if ($_.author -and $_.author.name) { [string]$_.author.name } elseif ($_.author -and $_.author.key) { [string]$_.author.key } else { "" }
          createdAt = [string]$_.created
          bodyHtml = if ($_.renderedBody) { [string]$_.renderedBody } else { "" }
          body = if ($_.body) { [string]$_.body } else { "" }
        }
      })
    }

    return @{
      Url = $url
      Comments = $comments
    }
  }
  catch {
    throw "Could not fetch Jira comments for $IssueKey. $($_.Exception.Message)"
  }
}

function Add-IssueComment {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$Body
  )

  $trimmed = $BaseUrl.TrimEnd("/")
  $url = "$trimmed/rest/api/2/issue/$IssueKey/comment"
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
    "Content-Type" = "application/json"
  }
  $payload = @{ body = $Body } | ConvertTo-Json -Depth 4

  try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $payload
    return @{
      Url = $url
      Id = if ($response -and $response.id) { [string]$response.id } else { "" }
      Created = if ($response -and $response.created) { [string]$response.created } else { "" }
    }
  }
  catch {
    throw "Could not post Jira comment for $IssueKey. $($_.Exception.Message)"
  }
}

function Get-IssueTransitions {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $trimmed = $BaseUrl.TrimEnd("/")
  $url = "$trimmed/rest/api/2/issue/$IssueKey/transitions"
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
  }

  try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    return @($response.transitions)
  }
  catch {
    throw "Could not fetch Jira transitions for $IssueKey. $($_.Exception.Message)"
  }
}

function Resolve-Issue {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $transitions = @(Get-IssueTransitions -BaseUrl $BaseUrl -IssueKey $IssueKey -Token $Token)
  $transition = $transitions | Where-Object {
    $name = if ($_.name) { [string]$_.name } else { "" }
    $toName = if ($_.to -and $_.to.name) { [string]$_.to.name } else { "" }
    $name -match '^(Resolved|Resolve Issue)$' -or $toName -match '^Resolved$'
  } | Select-Object -First 1

  if (-not $transition) {
    $available = @($transitions | ForEach-Object {
      if ($_.name) { [string]$_.name } elseif ($_.id) { [string]$_.id } else { "" }
    } | Where-Object { $_ }) -join ", "
    if (-not $available) { $available = "none" }
    throw "Could not find a Jira transition to Resolved for $IssueKey. Available transitions: $available"
  }

  $trimmed = $BaseUrl.TrimEnd("/")
  $url = "$trimmed/rest/api/2/issue/$IssueKey/transitions"
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
    "Content-Type" = "application/json"
  }
  $payload = @{
    transition = @{
      id = [string]$transition.id
    }
  } | ConvertTo-Json -Depth 4

  try {
    Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $payload | Out-Null
    return @{
      TransitionId = [string]$transition.id
      TransitionName = if ($transition.name) { [string]$transition.name } else { "Resolved" }
    }
  }
  catch {
    throw "Could not transition $IssueKey to Resolved. $($_.Exception.Message)"
  }
}

function Set-IssueAssignee {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$Assignee
  )

  $trimmed = $BaseUrl.TrimEnd("/")
  $url = "$trimmed/rest/api/2/issue/$IssueKey/assignee"
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
    "Content-Type" = "application/json"
  }
  $payload = @{ name = $Assignee } | ConvertTo-Json -Depth 3

  try {
    Invoke-RestMethod -Uri $url -Headers $headers -Method Put -Body $payload | Out-Null
    return @{
      Assignee = $Assignee
    }
  }
  catch {
    throw "Could not reassign $IssueKey to $Assignee. $($_.Exception.Message)"
  }
}

function Read-RequestJson {
  param(
    [Parameter(Mandatory = $true)]$Request
  )

  $encoding = if ($Request.ContentEncoding) { $Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
  $reader = [System.IO.StreamReader]::new($Request.InputStream, $encoding)
  try {
    $body = $reader.ReadToEnd()
  }
  finally {
    $reader.Close()
  }

  if (-not $body) {
    return $null
  }

  return $body | ConvertFrom-Json
}

function Read-RequestBodyText {
  param(
    [Parameter(Mandatory = $true)]$Request
  )

  $encoding = if ($Request.ContentEncoding) { $Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
  $reader = [System.IO.StreamReader]::new($Request.InputStream, $encoding)
  try {
    return $reader.ReadToEnd()
  }
  finally {
    $reader.Close()
  }
}

function Convert-FormBodyToMap {
  param(
    [string]$Body
  )

  $map = @{}
  foreach ($pair in ([string]$Body -split "&")) {
    if (-not $pair) { continue }
    $parts = $pair -split "=", 2
    $key = [System.Uri]::UnescapeDataString((($parts[0] -replace "\+", " ")))
    $value = if ($parts.Length -gt 1) { [System.Uri]::UnescapeDataString((($parts[1] -replace "\+", " "))) } else { "" }
    if ($key) {
      $map[$key] = $value
    }
  }
  return $map
}

function Get-FieldString {
  param(
    $Fields,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not $Fields) {
    return ""
  }

  $property = $Fields.PSObject.Properties[$Name]
  if (-not $property -or $null -eq $property.Value) {
    return ""
  }

  return [string]$property.Value
}

function Get-PropertyValue {
  param(
    $Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if (-not $property) {
    return $null
  }

  return $property.Value
}

function Get-ConfigString {
  param(
    $Config,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-PropertyValue -Object $Config -Name $Name
  if ($null -eq $value) {
    return ""
  }

  return [string]$value
}

function Get-IssueMeta {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $trimmed = $BaseUrl.TrimEnd("/")
  $url = "$trimmed/rest/api/2/issue/$IssueKey?fields=summary,parent,duedate"
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
  }

  try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    $fields = Get-PropertyValue -Object $response -Name "fields"
    $parent = Get-PropertyValue -Object $fields -Name "parent"
    $parentFields = Get-PropertyValue -Object $parent -Name "fields"
    $parentKeyValue = Get-PropertyValue -Object $parent -Name "key"
    $parentKey = if ($null -ne $parentKeyValue) { [string]$parentKeyValue } else { "" }
    $parentSummary = Get-FieldString -Fields $parentFields -Name "summary"
    $parentDueDate = Get-FieldString -Fields $parentFields -Name "duedate"

    if ($parentKey -and -not $parentSummary) {
      $parentUrl = "$trimmed/rest/api/2/issue/$parentKey?fields=summary,duedate"
      $parentResponse = Invoke-RestMethod -Uri $parentUrl -Headers $headers -Method Get
      $parentResponseFields = if ($parentResponse -and $parentResponse.fields) { $parentResponse.fields } else { $null }
      if ($parentResponseFields) {
        if (-not $parentSummary) {
          $parentSummary = Get-FieldString -Fields $parentResponseFields -Name "summary"
        }
        if (-not $parentDueDate) {
          $parentDueDate = Get-FieldString -Fields $parentResponseFields -Name "duedate"
        }
      }
    }

    return @{
      Url = $url
      IssueKey = $IssueKey
      Summary = Get-FieldString -Fields $fields -Name "summary"
      DueDate = Get-FieldString -Fields $fields -Name "duedate"
      ParentKey = $parentKey
      ParentSummary = $parentSummary
      ParentDueDate = $parentDueDate
    }
  }
  catch {
    throw "Could not fetch Jira metadata for $IssueKey. $($_.Exception.Message)"
  }
}

function Get-HomepageWorkbookPath {
  param(
    [string]$ConfiguredPath
  )

  $targetFileName = "NEW PK Weekly Game Plan, LTO, Daily Homepages.xlsx"
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($ConfiguredPath) {
    $candidates.Add([string]$ConfiguredPath)
  }

  $candidates.Add((Join-Path -Path $env:USERPROFILE -ChildPath "OneDrive - Williams-Sonoma Inc\PBK Ecom - Builds & Promos\$targetFileName"))
  $candidates.Add((Join-Path -Path $env:USERPROFILE -ChildPath "OneDrive\PBK Ecom - Builds & Promos\$targetFileName"))
  $candidates.Add((Join-Path -Path $env:USERPROFILE -ChildPath "OneDrive - Williams-Sonoma Inc\Desktop\All Downloads\$targetFileName"))

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not $candidate) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  # Search synced OneDrive locations for the live workbook before giving up.
  $searchRoots = @(
    (Join-Path -Path $env:USERPROFILE -ChildPath "OneDrive"),
    (Join-Path -Path $env:USERPROFILE -ChildPath "OneDrive - Williams-Sonoma Inc")
  ) | Select-Object -Unique

  foreach ($root in $searchRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    try {
      $match = Get-ChildItem -LiteralPath $root -Filter $targetFileName -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
      if ($match) {
        return $match.FullName
      }
    }
    catch {
      continue
    }
  }

  throw "Could not find the homepage workbook. Checked: $($candidates -join '; ')"
}

function Get-HomepageSchedulePath {
  param(
    [string]$ConfiguredPath
  )

  $candidates = New-Object System.Collections.Generic.List[string]
  if ($ConfiguredPath) {
    $candidates.Add([string]$ConfiguredPath)
  }
  $candidates.Add((Join-Path -Path $PSScriptRoot -ChildPath "homepage-testers.json"))

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not $candidate) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  return ""
}

function Get-WeekStartIsoDate {
  param(
    [Parameter(Mandatory = $true)][string]$DateText
  )

  try {
    $date = [datetime]::Parse($DateText)
  }
  catch {
    throw "Could not parse ticket date '$DateText' for tester lookup."
  }

  $offset = ([int]$date.DayOfWeek + 6) % 7
  return $date.Date.AddDays(-$offset).ToString("yyyy-MM-dd")
}

function Get-HomepageMerchTestersFromSchedule {
  param(
    [Parameter(Mandatory = $true)][string]$SchedulePath,
    [Parameter(Mandatory = $true)][string]$DateText
  )

  $weekStart = Get-WeekStartIsoDate -DateText $DateText
  $schedule = Read-JsonFile -Path $SchedulePath
  if (-not $schedule) {
    throw "Could not read the homepage tester schedule."
  }

  $entries = @()
  if ($schedule.entries) {
    $entries = @($schedule.entries)
  }
  elseif ($schedule -is [System.Array]) {
    $entries = @($schedule)
  }

  $match = $entries | Where-Object { [string]$_.weekStart -eq $weekStart } | Select-Object -First 1
  if (-not $match) {
    throw "Could not find tester schedule entry for the week of $weekStart."
  }

  $rawMerch = [string]$match.merchRaw
  if (-not $rawMerch) {
    $rawMerch = [string]$match.merchOwner
  }

  return @{
    workbookPath = $SchedulePath
    sheetName = "weekly-schedule"
    merchRaw = $rawMerch
    merchTesters = @(Split-HomepageNames -Value $rawMerch)
  }
}

function Normalize-HomepageSheetName {
  param(
    [string]$Name
  )

  return ([string]$Name).Trim().ToLowerInvariant().Replace(" ", "").Replace("_", ".").Replace("-", ".").Replace("/", ".")
}

function Get-HomepageSheetCandidates {
  param(
    [Parameter(Mandatory = $true)][string]$DateText
  )

  try {
    $date = [datetime]::Parse($DateText)
  }
  catch {
    throw "Could not parse ticket date '$DateText' for homepage lookup."
  }

  $month = $date.Month
  $day = $date.Day
  $yearShort = $date.ToString("yy")

  return @(
    "$month.$day.$yearShort"
    "$month/$day/$yearShort"
    "$month-$day-$yearShort"
    "$month.$day"
    "$month/$day"
    "$month-$day"
  ) | ForEach-Object { Normalize-HomepageSheetName $_ } | Select-Object -Unique
}

$script:HomepageWorkbookCache = @{
  WorkbookPath = ""
  LastWriteUtc = ""
  Sheets = @()
}

$script:HomepageTabListCache = @{
  WorkbookPath = ""
  LastWriteUtc = ""
  Tabs = @()
  DocName = ""
}

$script:HomepageMerchTesterCache = @{}

function Get-HomepageWorkbookCacheStamp {
  param(
    [Parameter(Mandatory = $true)][string]$WorkbookPath
  )

  return (Get-Item -LiteralPath $WorkbookPath).LastWriteTimeUtc.ToString("o")
}

function Find-HomepageSheetEntry {
  param(
    [Parameter(Mandatory = $true)][object[]]$Sheets,
    [Parameter(Mandatory = $true)][string]$DateText
  )

  $candidates = Get-HomepageSheetCandidates -DateText $DateText

  foreach ($candidate in $candidates) {
    foreach ($sheet in $Sheets) {
      $normalizedSheetName = [string]$sheet.Normalized
      if ($normalizedSheetName -eq $candidate -or $normalizedSheetName.StartsWith("$candidate.")) {
        return $sheet
      }
    }
  }

  $date = [datetime]::Parse($DateText)
  $month = $date.Month
  $day = $date.Day
  $yearShort = $date.ToString("yy")
  $prefixWithYear = "^{0}\.{1}\.{2}(?:\.|$)" -f [regex]::Escape([string]$month), [regex]::Escape([string]$day), [regex]::Escape($yearShort)
  $prefixWithoutYear = "^{0}\.{1}(?:\.|$)" -f [regex]::Escape([string]$month), [regex]::Escape([string]$day)

  foreach ($sheet in $Sheets) {
    $normalizedSheetName = [string]$sheet.Normalized
    if ($normalizedSheetName -match $prefixWithYear -or $normalizedSheetName -match $prefixWithoutYear) {
      return $sheet
    }
  }

  throw "Could not find a homepage tab for $DateText. Tried: $($candidates -join ', ')"
}

function Find-HomepageWorksheet {
  param(
    [Parameter(Mandatory = $true)]$Workbook,
    [Parameter(Mandatory = $true)][string]$DateText
  )

  $candidates = Get-HomepageSheetCandidates -DateText $DateText
  $worksheets = @()
  $worksheetCount = [int]$Workbook.Worksheets.Count
  for ($index = 1; $index -le $worksheetCount; $index++) {
    $worksheets += $Workbook.Worksheets.Item($index)
  }

  foreach ($candidate in $candidates) {
    foreach ($sheet in $worksheets) {
      $normalizedSheetName = Normalize-HomepageSheetName $sheet.Name
      if ($normalizedSheetName -eq $candidate -or $normalizedSheetName.StartsWith("$candidate.")) {
        return $sheet
      }
    }
  }

  $date = [datetime]::Parse($DateText)
  $month = $date.Month
  $day = $date.Day
  $yearShort = $date.ToString("yy")
  $prefixWithYear = "^{0}\.{1}\.{2}(?:\.|$)" -f [regex]::Escape([string]$month), [regex]::Escape([string]$day), [regex]::Escape($yearShort)
  $prefixWithoutYear = "^{0}\.{1}(?:\.|$)" -f [regex]::Escape([string]$month), [regex]::Escape([string]$day)

  foreach ($sheet in $worksheets) {
    $normalizedSheetName = Normalize-HomepageSheetName $sheet.Name
    if ($normalizedSheetName -match $prefixWithYear -or $normalizedSheetName -match $prefixWithoutYear) {
      return $sheet
    }
  }

  throw "Could not find a homepage tab for $DateText. Tried: $($candidates -join ', ')"
}

function Split-HomepageNames {
  param(
    [string]$Value
  )

  $normalized = [string]$Value
  $normalized = $normalized -replace '\s*&\s*', ','
  $normalized = $normalized -replace '\s+and\s+', ','
  $normalized = $normalized -replace '/', ','
  $normalized = $normalized -replace '\s{2,}', ' '

  return @(
    ($normalized -split ',') |
      ForEach-Object { ([string]$_).Trim() } |
      Where-Object { $_ }
  )
}

function Get-MerchTesterValueFromWorksheet {
  param(
    [Parameter(Mandatory = $true)]$Worksheet
  )

  $usedRange = $Worksheet.UsedRange
  $rowCount = [int]$usedRange.Rows.Count
  $colCount = [int]$usedRange.Columns.Count

  for ($row = 1; $row -le $rowCount; $row++) {
    for ($col = 1; $col -le $colCount; $col++) {
      $cellText = ([string]$usedRange.Item($row, $col).Text).Trim()
      if (-not $cellText) { continue }

      $inlineMatch = [regex]::Match($cellText, 'Merch Tester(?:s)?\s*:\s*(.+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($inlineMatch.Success) {
        return $inlineMatch.Groups[1].Value.Trim()
      }

      if ($cellText -match 'Merch Tester(?:s)?\s*:?\s*$') {
        for ($nextCol = $col + 1; $nextCol -le $colCount; $nextCol++) {
          $neighbor = ([string]$usedRange.Item($row, $nextCol).Text).Trim()
          if ($neighbor) {
            return $neighbor
          }
        }
      }
    }
  }

  throw "Could not find a 'Merch Tester' cell on the '$($Worksheet.Name)' tab."
}

function Test-IsHomepageRedColor {
  param(
    [object]$ColorValue
  )

  try {
    $color = [int]$ColorValue
  }
  catch {
    return $false
  }

  if ($color -le 0) {
    return $false
  }

  $red = $color -band 0xFF
  $green = ($color -shr 8) -band 0xFF
  $blue = ($color -shr 16) -band 0xFF

  return ($red -ge 150 -and $red -ge ($green + 35) -and $red -ge ($blue + 35))
}

function Get-HomepageColumnHeaders {
  param(
    [Parameter(Mandatory = $true)]$Worksheet
  )

  $usedRange = $Worksheet.UsedRange
  $rowCount = [Math]::Min([int]$usedRange.Rows.Count, 10)
  $colCount = [Math]::Min([int]$usedRange.Columns.Count, 20)
  $bestRow = 0
  $bestScore = -1

  for ($row = 1; $row -le $rowCount; $row++) {
    $nonEmpty = 0
    $shortCells = 0
    for ($col = 1; $col -le $colCount; $col++) {
      $text = ([string]$usedRange.Item($row, $col).Text).Trim()
      if (-not $text) { continue }
      $nonEmpty++
      if ($text.Length -le 32) {
        $shortCells++
      }
    }

    $score = ($nonEmpty * 10) + $shortCells
    if ($nonEmpty -ge 2 -and $score -gt $bestScore) {
      $bestScore = $score
      $bestRow = $row
    }
  }

  $headers = @{}
  if ($bestRow -le 0) {
    return $headers
  }

  for ($col = 1; $col -le $colCount; $col++) {
    $text = ([string]$usedRange.Item($bestRow, $col).Text).Trim()
    if ($text) {
      $headers[$col] = ($text -replace '\s+', ' ').Trim()
    }
  }

  return $headers
}

function Normalize-HomepageLabelKey {
  param(
    [string]$Value
  )

  return (([string]$Value).ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim()
}

function Find-HomepagePageRange {
  param(
    [Parameter(Mandatory = $true)]$Worksheet,
    [Parameter(Mandatory = $true)][string]$PageName
  )

  $usedRange = $Worksheet.UsedRange
  $rowCount = [Math]::Min([int]$usedRange.Rows.Count, 12)
  $colCount = [Math]::Min([int]$usedRange.Columns.Count, 40)
  $target = Normalize-HomepageLabelKey $PageName

  for ($row = 1; $row -le $rowCount; $row++) {
    for ($col = 1; $col -le $colCount; $col++) {
      $cellText = ([string]$usedRange.Item($row, $col).Text).Trim()
      if (-not $cellText) { continue }
      if ((Normalize-HomepageLabelKey $cellText) -ne $target) { continue }

      $cell = $usedRange.Item($row, $col)
      if ($cell.MergeCells) {
        $merge = $cell.MergeArea
        return @{
          StartColumn = [int]$merge.Column
          EndColumn = [int]($merge.Column + $merge.Columns.Count - 1)
          HeaderRow = [int]$merge.Row
        }
      }

      return @{
        StartColumn = $col
        EndColumn = $col
        HeaderRow = $row
      }
    }
  }

  return $null
}

function Resolve-HomepageColumnHeader {
  param(
    [hashtable]$Headers,
    [int]$Column
  )

  if ($Headers -and $Headers.ContainsKey($Column)) {
    return [string]$Headers[$Column]
  }

  return ""
}

function Get-HomepageRowLabel {
  param(
    [Parameter(Mandatory = $true)]$UsedRange,
    [Parameter(Mandatory = $true)][int]$Row,
    [Parameter(Mandatory = $true)][int]$StartColumn,
    [Parameter(Mandatory = $true)][int]$EndColumn,
    [Parameter(Mandatory = $true)][int]$CurrentColumn
  )

  $totalColumns = [Math]::Min([int]$UsedRange.Columns.Count, 40)

  # In the homepage workbook, the row label lives at the first populated cell in the row
  # (for example "Hero Top Banner 1"), while the red note text sits farther right.
  # Prefer that leftmost populated cell so filtering can key off the actual section name.
  for ($col = 1; $col -le $totalColumns; $col++) {
    if ($col -eq $CurrentColumn) { continue }
    $text = ([string]$UsedRange.Item($Row, $col).Text).Trim()
    if ($text) {
      return ($text -replace '\s+', ' ').Trim()
    }
  }

  return ""
}

function Get-HomepageRedNotesFromWorksheet {
  param(
    [Parameter(Mandatory = $true)]$Worksheet,
    [string]$PageName = ""
  )

  $usedRange = $Worksheet.UsedRange
  $rowCount = [Math]::Min([int]$usedRange.Rows.Count, 40)
  $colCount = [Math]::Min([int]$usedRange.Columns.Count, 40)
  $startColumn = 1
  $endColumn = $colCount
  $headerRow = 0

  if ($PageName) {
    $pageRange = Find-HomepagePageRange -Worksheet $Worksheet -PageName $PageName
    if ($pageRange) {
      $startColumn = [int]$pageRange.StartColumn
      $endColumn = [int]$pageRange.EndColumn
      $headerRow = [int]$pageRange.HeaderRow
    }
  }

  $headers = Get-HomepageColumnHeaders -Worksheet $Worksheet
  $notes = New-Object System.Collections.Generic.List[object]
  $rowsWithRed = @{}

  for ($row = [Math]::Max($headerRow + 1, 1); $row -le $rowCount; $row++) {
    $hasRed = $false

    for ($col = $startColumn; $col -le $endColumn; $col++) {
      $cell = $null
      try {
        $cell = $usedRange.Item($row, $col)
        $cellText = ([string]$cell.Text).Trim()
        if (-not $cellText) { continue }

        $fontColor = 0
        try {
          $fontColor = [int]$cell.DisplayFormat.Font.Color
        }
        catch {
          try {
            $fontColor = [int]$cell.Font.Color
          }
          catch {
            $fontColor = 0
          }
        }

        if (Test-IsHomepageRedColor -ColorValue $fontColor) {
          $hasRed = $true
          break
        }
      }
      finally {
        if ($null -ne $cell) {
          try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($cell) } catch {}
        }
      }
    }

    if ($hasRed) {
      $rowsWithRed[$row] = $true
    }
  }

  for ($row = [Math]::Max($headerRow + 1, 1); $row -le $rowCount; $row++) {
    if (-not $rowsWithRed.ContainsKey($row)) { continue }

    for ($col = $startColumn; $col -le $endColumn; $col++) {
      $cell = $null
      try {
        $cell = $usedRange.Item($row, $col)
        $cellText = ([string]$cell.Text).Trim()
        if (-not $cellText) { continue }

        $normalized = ($cellText -replace '\s+', ' ').Trim()
        if ($normalized.Length -lt 3) { continue }
        $header = Resolve-HomepageColumnHeader -Headers $headers -Column $col
        if (-not $header) {
          $header = "General"
        }
        $rowLabel = Get-HomepageRowLabel -UsedRange $usedRange -Row $row -StartColumn $startColumn -EndColumn $endColumn -CurrentColumn $col
        if (-not $rowLabel) {
          $rowLabel = $header
        }

        $notes.Add([pscustomobject]@{
          Header = $header
          RowLabel = $rowLabel
          Text = $normalized
        })
      }
      finally {
        if ($null -ne $cell) {
          try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($cell) } catch {}
        }
      }
    }
  }

  return @($notes | Group-Object { "$($_.Header)|$($_.Text)" } | ForEach-Object { $_.Group[0] })
}

function Open-HomepageWorkbookTemp {
  param(
    [Parameter(Mandatory = $true)][string]$WorkbookPath
  )

  $resolvedPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
  $tempWorkbookPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("homepage-workbook-" + [guid]::NewGuid().ToString("N") + ".xlsx")
  Copy-Item -LiteralPath $resolvedPath -Destination $tempWorkbookPath -Force

  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $workbook = $excel.Workbooks.Open($tempWorkbookPath, 0, $true)

  return @{
    Excel = $excel
    Workbook = $workbook
    TempPath = $tempWorkbookPath
    ResolvedPath = $resolvedPath
  }
}

function Close-HomepageWorkbookTemp {
  param(
    $Excel,
    $Workbook,
    [string]$TempPath
  )

  if ($null -ne $Workbook) {
    try { $Workbook.Close($false) } catch {}
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Workbook) } catch {}
  }
  if ($null -ne $Excel) {
    try { $Excel.Quit() } catch {}
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Excel) } catch {}
  }
  if ($TempPath -and (Test-Path -LiteralPath $TempPath -PathType Leaf)) {
    try { Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue } catch {}
  }
  [gc]::Collect()
  [gc]::WaitForPendingFinalizers()
}

function Get-CachedHomepageWorkbookSheets {
  param(
    [Parameter(Mandatory = $true)][string]$WorkbookPath
  )

  $resolvedPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
  $stamp = Get-HomepageWorkbookCacheStamp -WorkbookPath $resolvedPath

  if (
    $script:HomepageWorkbookCache.WorkbookPath -eq $resolvedPath -and
    $script:HomepageWorkbookCache.LastWriteUtc -eq $stamp -and
    @($script:HomepageWorkbookCache.Sheets).Count
  ) {
    return @($script:HomepageWorkbookCache.Sheets)
  }

  $excel = $null
  $workbook = $null
  $tempWorkbookPath = ""
  $sheetEntries = New-Object System.Collections.Generic.List[object]
  try {
    $opened = Open-HomepageWorkbookTemp -WorkbookPath $resolvedPath
    $excel = $opened.Excel
    $workbook = $opened.Workbook
    $tempWorkbookPath = $opened.TempPath
    $worksheetCount = [int]$workbook.Worksheets.Count

    for ($index = 1; $index -le $worksheetCount; $index++) {
      $worksheet = $null
      try {
        $worksheet = $workbook.Worksheets.Item($index)
        $sheetName = [string]$worksheet.Name
        $rawMerch = ""
        try {
          $rawMerch = [string](Get-MerchTesterValueFromWorksheet -Worksheet $worksheet)
        }
        catch {
          $rawMerch = ""
        }

        $sheetEntries.Add([pscustomobject]@{
          Name = $sheetName
          Normalized = (Normalize-HomepageSheetName $sheetName)
          MerchRaw = $rawMerch
        })
      }
      finally {
        if ($null -ne $worksheet) {
          try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($worksheet) } catch {}
        }
      }
    }
  }
  finally {
    Close-HomepageWorkbookTemp -Excel $excel -Workbook $workbook -TempPath $tempWorkbookPath
  }

  $script:HomepageWorkbookCache = @{
    WorkbookPath = $resolvedPath
    LastWriteUtc = $stamp
    Sheets = @($sheetEntries)
  }

  return @($sheetEntries)
}

function Test-IsHomepageDateSheetName {
  param(
    [string]$SheetName
  )

  $normalized = Normalize-HomepageSheetName $SheetName
  if (-not $normalized) {
    return $false
  }

  return ($normalized -match '^\d{1,2}\.\d{1,2}(?:\.\d{2,4})?(?:\.|$)')
}

function Get-VisibleHomepageTabsFromWorkbook {
  param(
    [Parameter(Mandatory = $true)]$Workbook,
    [switch]$AnchorToActiveSheet
  )

  $visibleDateTabs = New-Object System.Collections.Generic.List[string]
  $worksheetCount = [int]$Workbook.Worksheets.Count

  for ($index = 1; $index -le $worksheetCount; $index++) {
    $worksheet = $null
    try {
      $worksheet = $Workbook.Worksheets.Item($index)
      $isVisible = $true
      try {
        $isVisible = ([int]$worksheet.Visible -eq -1)
      }
      catch {
        $isVisible = $true
      }
      if (-not $isVisible) {
        continue
      }
      $sheetName = [string]$worksheet.Name
      if ($sheetName -and (Test-IsHomepageDateSheetName -SheetName $sheetName)) {
        $visibleDateTabs.Add($sheetName)
      }
    }
    finally {
      if ($null -ne $worksheet) {
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($worksheet) } catch {}
      }
    }
  }

  $tabs = @($visibleDateTabs | Select-Object -Unique)
  if (-not $AnchorToActiveSheet -or $tabs.Count -le 4) {
    return $tabs
  }

  $activeSheetName = ""
  try {
    $activeSheetName = [string]$Workbook.ActiveSheet.Name
  }
  catch {
    $activeSheetName = ""
  }

  $activeIndex = if ($activeSheetName) { [array]::IndexOf($tabs, $activeSheetName) } else { -1 }
  if ($activeIndex -lt 0) {
    return ($tabs | Select-Object -Last 4)
  }

  $start = [Math]::Max(0, $activeIndex - 2)
  $remaining = $tabs.Count - $start
  if ($remaining -lt 4) {
    $start = [Math]::Max(0, $tabs.Count - 4)
  }

  return @($tabs[$start..([Math]::Min($start + 3, $tabs.Count - 1))])
}

function Get-OpenHomepageTabs {
  param(
    [Parameter(Mandatory = $true)][string]$WorkbookPath
  )

  $resolvedPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
  $excel = $null

  try {
    $excel = [System.Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application")
  }
  catch {
    return $null
  }

  if ($null -eq $excel) {
    return $null
  }

  $matchedWorkbook = $null
  try {
    $workbookCount = [int]$excel.Workbooks.Count
    for ($index = 1; $index -le $workbookCount; $index++) {
      $candidate = $null
      try {
        $candidate = $excel.Workbooks.Item($index)
        $candidatePath = ""
        try {
          $candidatePath = (Resolve-Path -LiteralPath ([string]$candidate.FullName)).Path
        }
        catch {
          $candidatePath = [string]$candidate.FullName
        }
        if ($candidatePath -and $candidatePath -ieq $resolvedPath) {
          $matchedWorkbook = $candidate
          $candidate = $null
          break
        }
      }
      finally {
        if ($null -ne $candidate) {
          try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($candidate) } catch {}
        }
      }
    }

    if ($null -eq $matchedWorkbook) {
      return $null
    }

    $tabs = @(Get-VisibleHomepageTabsFromWorkbook -Workbook $matchedWorkbook -AnchorToActiveSheet)
    return @{
      docName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
      tabs = $tabs
    }
  }
  finally {
    if ($null -ne $matchedWorkbook) {
      try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($matchedWorkbook) } catch {}
    }
    if ($null -ne $excel) {
      try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch {}
    }
  }
}

function Get-HomepageTabs {
  param(
    [Parameter(Mandatory = $true)][string]$WorkbookPath
  )

  try {
    $resolvedPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
    $stamp = Get-HomepageWorkbookCacheStamp -WorkbookPath $resolvedPath
    $openWorkbookTabs = Get-OpenHomepageTabs -WorkbookPath $resolvedPath
    if ($openWorkbookTabs -and @($openWorkbookTabs.tabs).Count) {
      return @{
        workbookPath = $resolvedPath
        docName = [string]$openWorkbookTabs.docName
        updatedAt = $stamp
        tabs = @($openWorkbookTabs.tabs)
      }
    }
    if (
      $script:HomepageTabListCache.WorkbookPath -eq $resolvedPath -and
      $script:HomepageTabListCache.LastWriteUtc -eq $stamp -and
      @($script:HomepageTabListCache.Tabs).Count
    ) {
      return @{
        workbookPath = $resolvedPath
        docName = [string]$script:HomepageTabListCache.DocName
        updatedAt = $stamp
        tabs = @($script:HomepageTabListCache.Tabs)
      }
    }

    $excel = $null
    $workbook = $null
    $tempWorkbookPath = ""
    try {
      $opened = Open-HomepageWorkbookTemp -WorkbookPath $resolvedPath
      $excel = $opened.Excel
      $workbook = $opened.Workbook
      $tempWorkbookPath = $opened.TempPath
      $tabs = @(Get-VisibleHomepageTabsFromWorkbook -Workbook $workbook)
    }
    finally {
      Close-HomepageWorkbookTemp -Excel $excel -Workbook $workbook -TempPath $tempWorkbookPath
    }

    if (-not $tabs.Count) {
      $tabs = @()
    }

    $docName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
    $script:HomepageTabListCache = @{
      WorkbookPath = $resolvedPath
      LastWriteUtc = $stamp
      Tabs = @($tabs)
      DocName = $docName
    }

    return @{
      workbookPath = $resolvedPath
      docName = $docName
      updatedAt = $stamp
      tabs = $tabs
    }
  }
  catch {
    throw "Could not read homepage tabs. $($_.Exception.Message)"
  }
}

function Get-HomepageMerchTesters {
  param(
    [string]$SchedulePath,
    [Parameter(Mandatory = $true)][string]$WorkbookPath,
    [Parameter(Mandatory = $true)][string]$DateText
  )

  if ($SchedulePath) {
    try {
      return Get-HomepageMerchTestersFromSchedule -SchedulePath $SchedulePath -DateText $DateText
    }
    catch {}
  }

  try {
    $resolvedPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
    $stamp = Get-HomepageWorkbookCacheStamp -WorkbookPath $resolvedPath
    $cacheKey = "$resolvedPath|$stamp|$DateText"
    if ($script:HomepageMerchTesterCache.ContainsKey($cacheKey)) {
      return $script:HomepageMerchTesterCache[$cacheKey]
    }

    $excel = $null
    $workbook = $null
    $worksheet = $null
    $tempWorkbookPath = ""
    try {
      $opened = Open-HomepageWorkbookTemp -WorkbookPath $resolvedPath
      $excel = $opened.Excel
      $workbook = $opened.Workbook
      $tempWorkbookPath = $opened.TempPath
      $worksheet = Find-HomepageWorksheet -Workbook $workbook -DateText $DateText
      $rawMerch = [string](Get-MerchTesterValueFromWorksheet -Worksheet $worksheet)
      if (-not $rawMerch) {
        throw "Could not find a 'Merch Tester' cell on the '$([string]$worksheet.Name)' tab."
      }

      $result = @{
        workbookPath = $resolvedPath
        sheetName = [string]$worksheet.Name
        merchRaw = [string]$rawMerch
        merchTesters = @(Split-HomepageNames -Value $rawMerch)
      }
      $script:HomepageMerchTesterCache[$cacheKey] = $result
      return $result
    }
    finally {
      if ($null -ne $worksheet) {
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($worksheet) } catch {}
      }
      Close-HomepageWorkbookTemp -Excel $excel -Workbook $workbook -TempPath $tempWorkbookPath
    }
  }
  catch {
    throw "Could not read the homepage workbook for $DateText. $($_.Exception.Message)"
  }
}

function Get-HomepageRedNotes {
  param(
    [Parameter(Mandatory = $true)][string]$WorkbookPath,
    [Parameter(Mandatory = $true)][string]$DateText,
    [string]$PageName = ""
  )

  $excel = $null
  $workbook = $null
  $worksheet = $null
  $tempWorkbookPath = ""
  try {
    $opened = Open-HomepageWorkbookTemp -WorkbookPath $WorkbookPath
    $excel = $opened.Excel
    $workbook = $opened.Workbook
    $tempWorkbookPath = $opened.TempPath
    $worksheet = Find-HomepageWorksheet -Workbook $workbook -DateText $DateText
    return @{
      workbookPath = $WorkbookPath
      sheetName = [string]$worksheet.Name
      notes = @(Get-HomepageRedNotesFromWorksheet -Worksheet $worksheet -PageName $PageName)
    }
  }
  catch {
    throw "Could not read the homepage workbook for $DateText. $($_.Exception.Message)"
  }
  finally {
    if ($null -ne $worksheet) {
      try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($worksheet) } catch {}
    }
    Close-HomepageWorkbookTemp -Excel $excel -Workbook $workbook -TempPath $tempWorkbookPath
  }
}

$config = Read-JsonFile -Path $ConfigPath
if (-not $config) {
  $config = Read-JsonFile -Path ".\jira-proxy.config.example.json"
}
if (-not $config) {
  $config = [pscustomobject]@{
    jiraBaseUrl = "https://jira.wsgc.com"
    port = 8765
  }
}

$jiraBaseUrl = [string]$config.jiraBaseUrl
$port = [int]$config.port
$staticRoot = $PSScriptRoot
$homepageSchedulePath = Get-HomepageSchedulePath -ConfiguredPath (Get-ConfigString -Config $config -Name "homepageTesterSchedulePath")
$homepageWorkbookPath = Get-HomepageWorkbookPath -ConfiguredPath (Get-ConfigString -Config $config -Name "homepageWorkbookPath")

if (-not $jiraBaseUrl) {
  throw "Missing jiraBaseUrl in config."
}

if (-not $PatToken) {
  $PatToken = $env:JIRA_PAT
}

if (-not $PatToken) {
  $PatToken = Read-Host "Paste your Jira personal access token"
}

if (-not $PatToken) {
  throw "No Jira personal access token was provided."
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

Set-Content -LiteralPath $PidFile -Value $PID -Encoding ascii

Write-Host ""
Write-Host "Jira helper server is running." -ForegroundColor Green
Write-Host "Base URL: $jiraBaseUrl"
Write-Host "Local URL: http://localhost:$port/"
Write-Host ""
Write-Host "Try these in your browser:"
Write-Host "  http://localhost:$port/app"
Write-Host "  http://localhost:$port/health"
Write-Host "  http://localhost:$port/ticket-xml?key=PKECOM-41673"
Write-Host "  http://localhost:$port/ticket-comments?key=PKECOM-41673"
Write-Host "  http://localhost:$port/ticket-meta?key=PKECOM-41673"
Write-Host "  http://localhost:$port/homepage-testers?date=2026-04-29"
Write-Host "  http://localhost:$port/homepage-tabs"
Write-Host "  POST http://localhost:$port/ticket-comment"
Write-Host ""
Write-Host "Press Ctrl+C to stop."
Write-Host ""

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $path = $request.Url.AbsolutePath

    if ($request.HttpMethod -eq "OPTIONS") {
      Write-TextResponse -Context $context -StatusCode 204 -Body ""
      continue
    }

    $staticPath = Resolve-StaticPath -RequestPath $path -RootPath $staticRoot
    if ($staticPath) {
      Write-FileResponse -Context $context -Path $staticPath
      continue
    }

    if ($path -eq "/health") {
      Write-JsonResponse -Context $context -Payload @{
        ok = $true
        jiraBaseUrl = $jiraBaseUrl
        port = $port
      }
      continue
    }

    if ($path -eq "/ticket-xml") {
      $issueKey = [string]$request.QueryString["key"]
      if (-not $issueKey) {
        Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
          ok = $false
          error = "Missing key query parameter."
        }
        continue
      }

      try {
        $result = Get-IssueXml -BaseUrl $jiraBaseUrl -IssueKey $issueKey -Token $PatToken
        Write-TextResponse -Context $context -ContentType "application/xml; charset=utf-8" -Body $result.Xml
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
          issueKey = $issueKey
        }
      }
      continue
    }

    if ($path -eq "/ticket-comments") {
      $issueKey = [string]$request.QueryString["key"]
      if (-not $issueKey) {
        Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
          ok = $false
          error = "Missing key query parameter."
        }
        continue
      }

      try {
        $result = Get-IssueComments -BaseUrl $jiraBaseUrl -IssueKey $issueKey -Token $PatToken
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          issueKey = $issueKey
          comments = $result.Comments
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
          issueKey = $issueKey
        }
      }
      continue
    }

    if ($path -eq "/ticket-comment") {
      if ($request.HttpMethod -ne "POST" -and $request.HttpMethod -ne "GET") {
        Write-JsonResponse -Context $context -StatusCode 405 -Payload @{
          ok = $false
          error = "Method not allowed. Use GET or POST."
        }
        continue
      }

      try {
        $contentType = [string]$request.ContentType
        $issueKey = ""
        $commentBody = ""

        if ($request.HttpMethod -eq "GET") {
          $issueKey = [string]$request.QueryString["key"]
          $commentBody = [string]$request.QueryString["body"]
        }
        elseif ($contentType -match "application/json") {
          $payload = Read-RequestJson -Request $request
          $issueKey = if ($payload -and $payload.key) { [string]$payload.key } else { "" }
          $commentBody = if ($payload -and $payload.body) { [string]$payload.body } else { "" }
        }
        else {
          $rawBody = Read-RequestBodyText -Request $request
          $form = Convert-FormBodyToMap -Body $rawBody
          if ($form.ContainsKey("key")) { $issueKey = [string]$form["key"] }
          if ($form.ContainsKey("body")) { $commentBody = [string]$form["body"] }
        }

        if (-not $issueKey) {
          Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
            ok = $false
            error = "Missing key in request body."
          }
          continue
        }
        if (-not $commentBody.Trim()) {
          Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
            ok = $false
            error = "Comment body cannot be empty."
            issueKey = $issueKey
          }
          continue
        }

        $result = Add-IssueComment -BaseUrl $jiraBaseUrl -IssueKey $issueKey -Token $PatToken -Body $commentBody
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          issueKey = $issueKey
          commentId = $result.Id
          createdAt = $result.Created
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
        }
      }
      continue
    }

    if ($path -eq "/ticket-ready-for-testing") {
      if ($request.HttpMethod -ne "POST" -and $request.HttpMethod -ne "GET") {
        Write-JsonResponse -Context $context -StatusCode 405 -Payload @{
          ok = $false
          error = "Method not allowed. Use GET or POST."
        }
        continue
      }

      try {
        $contentType = [string]$request.ContentType
        $issueKey = ""
        $assignee = ""

        if ($request.HttpMethod -eq "GET") {
          $issueKey = [string]$request.QueryString["key"]
          $assignee = [string]$request.QueryString["assignee"]
        }
        elseif ($contentType -match "application/json") {
          $payload = Read-RequestJson -Request $request
          $issueKey = if ($payload -and $payload.key) { [string]$payload.key } else { "" }
          $assignee = if ($payload -and $payload.assignee) { [string]$payload.assignee } else { "" }
        }
        else {
          $rawBody = Read-RequestBodyText -Request $request
          $form = Convert-FormBodyToMap -Body $rawBody
          if ($form.ContainsKey("key")) { $issueKey = [string]$form["key"] }
          if ($form.ContainsKey("assignee")) { $assignee = [string]$form["assignee"] }
        }

        if (-not $issueKey) {
          Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
            ok = $false
            error = "Missing key in request."
          }
          continue
        }
        if (-not $assignee.Trim()) {
          Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
            ok = $false
            error = "Missing assignee in request."
            issueKey = $issueKey
          }
          continue
        }

        $transitionResult = Resolve-Issue -BaseUrl $jiraBaseUrl -IssueKey $issueKey -Token $PatToken
        $assigneeResult = Set-IssueAssignee -BaseUrl $jiraBaseUrl -IssueKey $issueKey -Token $PatToken -Assignee $assignee
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          issueKey = $issueKey
          resolved = $true
          transitionId = $transitionResult.TransitionId
          transitionName = $transitionResult.TransitionName
          assignee = $assigneeResult.Assignee
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
        }
      }
      continue
    }

    if ($path -eq "/ticket-meta") {
      $issueKey = [string]$request.QueryString["key"]
      if (-not $issueKey) {
        Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
          ok = $false
          error = "Missing key query parameter."
        }
        continue
      }

      try {
        $result = Get-IssueMeta -BaseUrl $jiraBaseUrl -IssueKey $issueKey -Token $PatToken
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          issueKey = $issueKey
          summary = $result.Summary
          dueDate = $result.DueDate
          parentKey = $result.ParentKey
          parentSummary = $result.ParentSummary
          parentDueDate = $result.ParentDueDate
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
          issueKey = $issueKey
        }
      }
      continue
    }

    if ($path -eq "/homepage-testers") {
      $dateText = [string]$request.QueryString["date"]
      if (-not $dateText) {
        Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
          ok = $false
          error = "Missing date query parameter."
        }
        continue
      }

      try {
        $result = Get-HomepageMerchTesters -SchedulePath $homepageSchedulePath -WorkbookPath $homepageWorkbookPath -DateText $dateText
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          date = $dateText
          schedulePath = $homepageSchedulePath
          workbookPath = $result.workbookPath
          sheetName = $result.sheetName
          merchRaw = $result.merchRaw
          merchTesters = $result.merchTesters
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
          date = $dateText
        }
      }
      continue
    }

    if ($path -eq "/homepage-red-notes") {
      $dateText = [string]$request.QueryString["date"]
      $pageName = [string]$request.QueryString["page"]
      if (-not $dateText) {
        Write-JsonResponse -Context $context -StatusCode 400 -Payload @{
          ok = $false
          error = "Missing date query parameter."
        }
        continue
      }

      try {
        $result = Get-HomepageRedNotes -WorkbookPath $homepageWorkbookPath -DateText $dateText -PageName $pageName
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          date = $dateText
          page = $pageName
          workbookPath = $result.workbookPath
          sheetName = $result.sheetName
          notes = $result.notes
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
          date = $dateText
        }
      }
      continue
    }

    if ($path -eq "/homepage-tabs") {
      try {
        $result = Get-HomepageTabs -WorkbookPath $homepageWorkbookPath
        Write-JsonResponse -Context $context -Payload @{
          ok = $true
          workbookPath = $result.workbookPath
          docName = $result.docName
          sheetName = $result.docName
          updatedAt = $result.updatedAt
          tabs = $result.tabs
        }
      }
      catch {
        Write-JsonResponse -Context $context -StatusCode 502 -Payload @{
          ok = $false
          error = $_.Exception.Message
        }
      }
      continue
    }

    Write-JsonResponse -Context $context -StatusCode 404 -Payload @{
      ok = $false
      error = "Route not found. Try /health, /ticket-xml?key=ABC-123, /ticket-comments?key=ABC-123, /ticket-comment, /ticket-ready-for-testing, /ticket-meta?key=ABC-123, /homepage-testers?date=YYYY-MM-DD, /homepage-red-notes?date=YYYY-MM-DD, or /homepage-tabs."
      route = $path
    }
  }
}
finally {
  if (Test-Path -LiteralPath $PidFile) {
    try {
      $storedPid = (Get-Content -LiteralPath $PidFile -Raw).Trim()
      if ($storedPid -eq [string]$PID) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
      }
    }
    catch {}
  }
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
}
