#requires -Version 7.0
<#
Read-only, on-demand content audit. Does not enumerate the vault root,
descend into subdirectories, follow reparse points, access Git/network,
write reports, or repair/delete notes. Run -SelfTest before changing it.
#>
[CmdletBinding()]
param(
    [string]$VaultPath = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 1000)][int]$DetailLimit = 20,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Remove-NonProse([string]$Text) {
    $result = [regex]::Replace($Text, '(?ms)^[ \t]*(`{3,}|~{3,})[^\r\n]*\r?\n.*?^[ \t]*\1[ \t]*\r?$', '')
    $result = [regex]::Replace($result, '(?s)<!--.*?-->|%%.*?%%', '')
    return [regex]::Replace($result, '`+[^`\r\n]*`+', '')
}

function New-Note([string]$Path, [string]$Raw, [bool]$Content = $true) {
    $front = [regex]::Match($Raw, '\A---\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|$)', 'Singleline')
    $body = if ($front.Success) { $Raw.Substring($front.Length) } else { $Raw }
    $aliases = [System.Collections.Generic.List[string]]::new()
    if ($front.Success) {
        # Common inline/block aliases only; this is not a general YAML parser.
        $inline = [regex]::Match($front.Groups['yaml'].Value, '(?m)^aliases:\s*\[([^\r\n]*)\]\s*$')
        if ($inline.Success) {
            foreach ($alias in ($inline.Groups[1].Value -split ',')) {
                $value = $alias.Trim().Trim('"', "'")
                if ($value) { $aliases.Add($value) }
            }
        }
        $block = [regex]::Match($front.Groups['yaml'].Value, '(?m)^aliases:[ \t]*\r?\n((?:[ \t]+-[^\r\n]+(?:\r?\n|$))+)')
        if ($block.Success) {
            foreach ($match in [regex]::Matches($block.Groups[1].Value, '(?m)^[ \t]+-[ \t]*(.+)$')) {
                $value = $match.Groups[1].Value.Trim().Trim('"', "'")
                if ($value) { $aliases.Add($value) }
            }
        }
    }
    [pscustomobject]@{
        Path = $Path; Name = [IO.Path]::GetFileNameWithoutExtension($Path)
        Body = $body; Prose = Remove-NonProse $body
        LinkText = Remove-NonProse $Raw; Aliases = @($aliases)
        Content = $Content
        BadFrontmatter = ($Raw -match '\A---\r?\n' -and -not $front.Success)
    }
}

function Test-Notes([object[]]$Notes) {
    $index = @{}; $incoming = @{}; $outgoing = @{}; $hashes = @{}
    $issues = [System.Collections.Generic.List[object]]::new()
    $omittedLinks = 0
    foreach ($note in $Notes) {
        $incoming[$note.Path] = 0; $outgoing[$note.Path] = 0
        $keys = @($note.Name, ($note.Path -replace '\.md$', '')) + @($note.Aliases)
        foreach ($key in ($keys | Sort-Object -Unique)) {
            if (-not $index.ContainsKey($key)) { $index[$key] = [System.Collections.Generic.List[string]]::new() }
            $index[$key].Add($note.Path)
        }
    }
    foreach ($note in $Notes) {
        foreach ($match in [regex]::Matches($note.LinkText, '\[\[([^\]\r\n]+)\]\]')) {
            $target = (($match.Groups[1].Value -split '\|', 2)[0] -split '#', 2)[0].Trim().Replace('\', '/')
            $target = $target -replace '\.md$', ''
            if (-not $target) { continue } # same-note headings/blocks
            if ($target -match '(^|/)(نظام-الزوايا-التسعة|\.vault-tools|sync-recovery[^/]*)(/|$)') {
                $omittedLinks++; continue
            }
            $relative = ([IO.Path]::GetDirectoryName($note.Path).Replace('\', '/') + '/' + $target)
            $resolved = @(if ($index.ContainsKey($target)) { $index[$target] }
                         elseif ($index.ContainsKey($relative)) { $index[$relative] })
            if ($resolved.Count -eq 1) {
                if ($resolved[0] -ne $note.Path) { $outgoing[$note.Path]++; $incoming[$resolved[0]]++ }
            } elseif ($note.Content) {
                $kind = if ($resolved.Count -gt 1) { 'ambiguous_target' } else { 'unresolved_in_scope' }
                $issues.Add([pscustomobject]@{Kind=$kind; File=$note.Path; Detail=$target})
            }
        }
        if (-not $note.Content) { continue }
        if ($note.BadFrontmatter) { $issues.Add([pscustomobject]@{Kind='unclosed_frontmatter'; File=$note.Path; Detail=''}) }
        $defs = @([regex]::Matches($note.Prose, '(?m)^\[\^([^\]]+)\]:') | ForEach-Object { $_.Groups[1].Value })
        $uses = @([regex]::Matches($note.Prose, '\[\^([^\]]+)\](?!:)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($foot in $uses) {
            if ($foot -notin $defs) { $issues.Add([pscustomobject]@{Kind='undefined_footnote'; File=$note.Path; Detail=$foot}) }
        }
        foreach ($group in ($defs | Group-Object | Where-Object Count -gt 1)) {
            $issues.Add([pscustomobject]@{Kind='duplicate_footnote'; File=$note.Path; Detail=$group.Name})
        }
        $plain = [regex]::Replace($note.Prose, '(?m)^#{1,6}\s+.*$', '').Trim()
        $wordCount = [regex]::Matches($plain, '\S+').Count
        if (-not $plain) { $issues.Add([pscustomobject]@{Kind='empty_body'; File=$note.Path; Detail=''}) }
        elseif ($wordCount -lt 60) { $issues.Add([pscustomobject]@{Kind='short_review_only'; File=$note.Path; Detail="$wordCount tokens; may be intentional"}) }
        if ($note.Prose -match '(?m)^(<<<<<<< |=======$|>>>>>>> )') {
            $issues.Add([pscustomobject]@{Kind='conflict_marker'; File=$note.Path; Detail=''})
        }
        # Exact normalized body, not a judgement of semantic similarity.
        $normalized = [regex]::Replace($note.Body.Trim(), '\s+', ' ')
        if ($normalized.Length -ge 100) {
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized)))
            if ($hashes.ContainsKey($hash)) {
                $issues.Add([pscustomobject]@{Kind='same_body_review_only'; File=$note.Path; Detail=$hashes[$hash]})
            } else { $hashes[$hash] = $note.Path }
        }
    }
    foreach ($note in $Notes) {
        if ($note.Content -and $incoming[$note.Path] -eq 0 -and $outgoing[$note.Path] -eq 0) {
            $issues.Add([pscustomobject]@{Kind='isolated_in_scope'; File=$note.Path; Detail='not a deletion candidate by itself'})
        }
    }
    [pscustomobject]@{Issues=@($issues); OmittedOutOfScopeLinks=$omittedLinks}
}

if ($SelfTest) {
    $sample = @(
        (New-Note 'الفلسفة/A.md' "---`naliases: [Alpha]`n---`n# A`n[[B]] [[C]]`nGood[^ok].`n[^ok]: source"),
        (New-Note 'الفلسفة/B.md' "# B`n[[Alpha]] [[Future]]`nBad[^lost].`n``````text`n[[CodeOnly]] [^ignored]`n``````"),
        (New-Note 'الفلسفة/C.md' "# C`n<!-- hidden -->"),
        (New-Note 'الفلسفة/D.md' "---`naliases:`n  - Delta`n---`n# D`n[[#Local]] [[Delta]]"),
        (New-Note 'الفلسفة/E.md' "---`ntitle: broken"),
        (New-Note 'الفلسفة/F.md' ("# Same`n" + ('some repeated prose ' * 12))),
        (New-Note 'الفلسفة/G.md' ("# Same`n" + ('some repeated prose ' * 12)))
    )
    $result = Test-Notes $sample
    $tests = [ordered]@{
        'undefined footnote detected' = (@($result.Issues | Where-Object Kind -eq 'undefined_footnote').Count -eq 1)
        'code examples ignored and aliases resolved' = (@($result.Issues | Where-Object Kind -eq 'unresolved_in_scope').Count -eq 1)
        'empty note detected' = (@($result.Issues | Where-Object Kind -eq 'empty_body').Count -eq 1)
        'unclosed metadata detected' = (@($result.Issues | Where-Object Kind -eq 'unclosed_frontmatter').Count -eq 1)
        'exact duplicate flagged for review' = (@($result.Issues | Where-Object Kind -eq 'same_body_review_only').Count -eq 1)
        'incoming-only note is not isolated' = (@($result.Issues | Where-Object { $_.Kind -eq 'isolated_in_scope' -and $_.File -eq 'الفلسفة/C.md' }).Count -eq 0)
    }
    foreach ($name in $tests.Keys) { if (-not $tests[$name]) { throw "Self-test failed: $name" } }
    [pscustomobject]@{Passed=$tests.Count; Failed=0; Mode='in-memory; no vault access'}
    return
}

$contentFolders = @('الفلسفة', 'الأسطورة-وعلم-الأديان-المقارن', 'الأدب-والفن', 'الأنثروبولوجيا', 'علم-النفس-العميق', 'التقاليد-الباطنية', 'التاريخ-والسياق', '٩٩-بذور-معلّقة')
$referenceFolders = @('٠٠-الفهرس', 'عقل-الدوكسوغراف')
$root = [IO.Path]::GetFullPath($VaultPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($root -match '(^|[\\/])(نظام-الزوايا-التسعة|\.vault-tools|sync-recovery[^\\/]*)([\\/]|$)') { throw 'Excluded root.' }
# Reject junctions/symlinks in the supplied root or its ancestors before reading notes.
$ancestor = $root
while ($ancestor) {
    $item = Get-Item -LiteralPath $ancestor -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse-point roots are not scanned.' }
    $ancestor = Split-Path -Parent $ancestor
}
$notes = [System.Collections.Generic.List[object]]::new()
$scannedFolders = [System.Collections.Generic.List[string]]::new()
foreach ($folder in ($contentFolders + $referenceFolders)) {
    $path = Join-Path $root $folder
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
    $directory = Get-Item -LiteralPath $path -Force
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $scannedFolders.Add($folder)
    foreach ($file in (Get-ChildItem -LiteralPath $path -File -Filter '*.md' | Sort-Object Name)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($file.Name -like '*sync-conflict*') { continue }
        $notes.Add((New-Note "$folder/$($file.Name)" (Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8) ($folder -in $contentFolders)))
    }
}
$result = Test-Notes @($notes)
$counts = [ordered]@{}
foreach ($group in ($result.Issues | Group-Object Kind | Sort-Object Name)) { $counts[$group.Name] = $group.Count }
$details = @($result.Issues | Group-Object Kind | Sort-Object Name | ForEach-Object { $_.Group | Select-Object -First $DetailLimit })
[pscustomobject]@{
    Date = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    IndexedNotes = $notes.Count
    ContentNotes = @($notes | Where-Object Content).Count
    DirectFolders = @($scannedFolders)
    Limits = 'Direct Markdown files only; no subfolders, personal gardens, archives, assets, network, Markdown-link/heading validation or source verification. Common alias syntax only.'
    OmittedOutOfScopeLinks = $result.OmittedOutOfScopeLinks
    Counts = $counts
    DetailLimitPerKind = $DetailLimit
    Findings = $details
} | ConvertTo-Json -Depth 7
