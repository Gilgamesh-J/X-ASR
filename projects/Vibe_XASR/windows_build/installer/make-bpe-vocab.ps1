# make-bpe-vocab.ps1 - generate an augmented sentencepiece-style bpe.vocab from tokens.txt for
# hotword tokenization (port of tools/hotwords_eval/make_bpe_vocab.py). score = -id reproduces the
# model's BPE merge ordering; bare CJK chars plus a standalone U+2581 (word-boundary marker) are
# added at very low scores so the tokenizer can bootstrap U+2581 X pieces (this model has no
# bare-char tokens). ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as the ANSI codepage.
param([Parameter(Mandatory)][string]$Tokens, [Parameter(Mandatory)][string]$Out)
function IsCjkO([int]$o) { ($o -ge 0x3400 -and $o -le 0x4DBF) -or ($o -ge 0x4E00 -and $o -le 0x9FFF) -or ($o -ge 0xF900 -and $o -le 0xFAFF) }
$rows = New-Object System.Collections.Generic.List[string]
$have = New-Object System.Collections.Generic.HashSet[string]
$bare = New-Object System.Collections.Generic.HashSet[string]
$U = [char]0x2581   # word-boundary marker
foreach ($ln in [IO.File]::ReadAllLines($Tokens)) {
    if (-not $ln) { continue }
    $i = $ln.LastIndexOf(' '); if ($i -lt 0) { continue }
    $piece = $ln.Substring(0, $i); $idx = 0
    if (-not [int]::TryParse($ln.Substring($i + 1), [ref]$idx)) { continue }
    $rows.Add("$piece`t$(-$idx)") | Out-Null
    [void]$have.Add($piece)
    if ($piece.Length -eq 2 -and $piece[0] -eq $U -and (IsCjkO([int]$piece[1]))) { [void]$bare.Add([string]$piece[1]) }
}
$extra = New-Object System.Collections.Generic.List[string]
if (-not $have.Contains([string]$U)) { $extra.Add("$U`t-1") | Out-Null }
foreach ($c in ($bare | Sort-Object)) { if (-not $have.Contains($c)) { $extra.Add("$c`t-999999") | Out-Null } }
[IO.File]::WriteAllLines($Out, ($rows + $extra), (New-Object Text.UTF8Encoding($false)))
Write-Host "  bpe.vocab: $($rows.Count) pieces + $($extra.Count) bootstrap ($($bare.Count) bare CJK)"
