<#
.SYNOPSIS
    Проверяет, что канон не разошёлся с реальностью.

.DESCRIPTION
    Канон утверждает: «стандарт, который никто не проверяет, дрейфует — и тогда он
    хуже отсутствия стандарта, потому что всё ещё выглядит авторитетно» (SDD.md).
    До 2026-08-18 это утверждение не распространялось на сам канон, и он честно
    дрейфовал: GLOSSARY.md утверждал, что у Studio и Desktop нет remote, — у обоих
    он был; CONTRACTS.md перечислял 4 файла артефактов из 7.

    Скрипт ловит ровно те расхождения, которые уже случались:

      1. висячая ссылка — markdown-линк или путь, за которым ничего нет;
      2. репозиторий, объявленный в ECOSYSTEM.md, отсутствует или без origin;
      3. остатки прежнего имени каталога артефактов в живых поверхностях;
      4. потребитель, выровненный не под ту редакцию канона.

    Проверок про содержание правил здесь нет намеренно: это дело валидатора
    приложения (`check_architecture.ps1`), который читает его `architecture.toml`.

.PARAMETER DevRoot
    Каталог, в котором лежат репозитории экосистемы. По умолчанию — родитель
    каталога канона.

.EXAMPLE
    .\tools\check_canon.ps1
#>
[CmdletBinding()]
param(
    [string]$DevRoot
)

$ErrorActionPreference = 'Stop'
# Скрипт живёт в tools/ (исполняется процессом разработки), корень канона — уровнем выше.
$canonRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $DevRoot) { $DevRoot = Split-Path -Parent $canonRoot }

$problems = New-Object System.Collections.Generic.List[string]
function Add-Problem([string]$where, [string]$what) {
    $problems.Add(("{0}: {1}" -f $where, $what))
}

$canonFiles = Get-ChildItem -Path $canonRoot -Filter *.md -File

# --------------------------------------------------------------- 1. ссылки
# Markdown-линки внутри канона обязаны разрешаться. Ссылка на несуществующий
# файл — это документ, который выглядит авторитетно и врёт.
foreach ($f in $canonFiles) {
    $text = Get-Content $f.FullName -Raw
    foreach ($m in [regex]::Matches($text, '\[[^\]]*\]\(([^)#]+)(?:#[^)]*)?\)')) {
        $target = $m.Groups[1].Value.Trim()
        if ($target -match '^[a-z][a-z0-9+.-]*://') { continue }   # внешний URL не проверяем
        $full = Join-Path $canonRoot $target
        if (-not (Test-Path $full)) {
            Add-Problem $f.Name "висячая ссылка [$target]"
        }
    }
}

# Абсолютные пути в обратных кавычках — тоже адреса, и тоже врут молча. Проверяются
# только пути внутри $DevRoot: за его пределами канон называет чужое — каталоги
# данных, мёртвые адреса из истории, — и требовать их существования нельзя.
foreach ($f in $canonFiles) {
    $text = Get-Content $f.FullName -Raw
    foreach ($m in [regex]::Matches($text, '`([A-Za-z]:\\[^`]+)`')) {
        $p = $m.Groups[1].Value.TrimEnd('\', '*')
        if ($p -match '[\*\?<>]') { continue }     # плейсхолдеры и globs адресами не являются
        if (-not ($p -like "$DevRoot*")) { continue }
        if (-not (Test-Path -LiteralPath $p)) {
            Add-Problem $f.Name "путь не существует: $p"
        }
    }
}

# ------------------------------------------------------------ 2. участники
# ECOSYSTEM.md — единственное место в каноне, где вообще названы репозитории.
# Значит именно он обязан быть правдой.
$ecosystem = Get-Content (Join-Path $canonRoot 'ECOSYSTEM.md') -Raw
$declared = [regex]::Matches($ecosystem, '(?m)^\|\s*`(sdd[a-z_]*)`\s*\|') |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique

if ($declared.Count -lt 2) {
    Add-Problem 'ECOSYSTEM.md' 'таблица участников не разобралась — проверь её формат'
}

foreach ($repo in $declared) {
    $path = Join-Path $DevRoot $repo
    if (-not (Test-Path $path)) {
        Add-Problem 'ECOSYSTEM.md' "объявлен репозиторий $repo, но каталога нет: $path"
        continue
    }
    if (-not (Test-Path (Join-Path $path '.git'))) {
        Add-Problem $repo 'каталог не под git'
        continue
    }
    $remote = & git -C $path remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $remote) {
        Add-Problem $repo 'нет origin — репозиторий существует только на этой машине'
    }
}

# ------------------------------------------------- 3. остатки прежних имён
# Имя каталога артефактов — носитель стыка №2. Прежнее имя, вернувшееся в живую
# поверхность, рвёт стык молча: приложение просто перестаёт публиковать метрику.
$liveSurfaces = @(
    @{ Repo = 'sdd_studio';  Paths = @('src') }
    @{ Repo = 'sdd_mpi_app'; Paths = @('tools', 'crates', '.gitignore', 'architecture.toml', 'CLAUDE.md') }
)
foreach ($s in $liveSurfaces) {
    foreach ($rel in $s.Paths) {
        $p = Join-Path (Join-Path $DevRoot $s.Repo) $rel
        if (-not (Test-Path $p)) { continue }
        $targets = @(Get-Item -LiteralPath $p)
        if ($targets[0].PSIsContainer) {
            $targets = @(Get-ChildItem -LiteralPath $p -Recurse -File)
        }
        $hits = $targets | Select-String -Pattern '.vsa_designer' -SimpleMatch -ErrorAction SilentlyContinue
        foreach ($h in $hits) {
            # Упоминание в комментарии — история («переименовано из …»), и она полезна.
            # Ломает стык только использование: строка, путь, ключ.
            if ($h.Line.TrimStart() -match '^(#|//|\*)') { continue }
            Add-Problem $s.Repo ("прежнее имя каталога артефактов в {0}:{1}" -f $h.Filename, $h.LineNumber)
        }
    }
    $stale = Join-Path (Join-Path $DevRoot $s.Repo) '.vsa_designer'
    if (Test-Path $stale) {
        Add-Problem $s.Repo 'на диске остался каталог .vsa_designer — метрика будет читаться из старого'
    }
}

# --------------------------------------------------------- 4. версия канона
# Потребитель объявляет, под какую редакцию он выровнен. Отставание — не ошибка,
# опережение — ошибка: значит канон откатили, а приложение нет.
$changelog = Get-Content (Join-Path $canonRoot 'CHANGELOG.md') -Raw
$m = [regex]::Match($changelog, '(?m)^##\s+(\d+)\.(\d+)\.(\d+)')
if (-not $m.Success) {
    Add-Problem 'CHANGELOG.md' 'не нашёл номер текущей редакции (ожидается заголовок вида "## 1.0.0")'
} else {
    $canonVersion = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
    Write-Host ("[canon] редакция {0}" -f $canonVersion) -ForegroundColor DarkGray

    foreach ($repo in $declared) {
        $manifest = Join-Path (Join-Path $DevRoot $repo) 'architecture.toml'
        if (-not (Test-Path $manifest)) { continue }
        $mm = [regex]::Match((Get-Content $manifest -Raw), '(?m)^\s*canon_version\s*=\s*"([^"]+)"')
        if (-not $mm.Success) {
            Add-Problem $repo 'architecture.toml без [meta] canon_version — не сказать, под какую редакцию выровнен'
            continue
        }
        $declaredVersion = [version]$mm.Groups[1].Value
        if ($declaredVersion -gt $canonVersion) {
            Add-Problem $repo ("объявлен canon_version {0}, а канон {1}" -f $declaredVersion, $canonVersion)
        } elseif ($declaredVersion -lt $canonVersion) {
            Write-Host ("[canon] {0}: выровнен под {1}, канон {2} — миграция не сделана" -f `
                $repo, $declaredVersion, $canonVersion) -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------------- итог
if ($problems.Count -eq 0) {
    Write-Host '[canon] OK — канон и экосистема сходятся.' -ForegroundColor Green
    exit 0
}

Write-Host ("[canon] расхождений: {0}" -f $problems.Count) -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
exit 1
