# ============================================================
# GitHub Contributed Repos Discovery Script
# Run periodically to refresh the repo list for metrics-people
# workflow. Combines two methods:
#   1. GraphQL contributionsCollection (year by year, 2015-now)
#   2. REST API org repo scan (docc-lab, docclab-docs)
# ============================================================

# --- Setup ---
$token = gh auth token
$username = "RoyZhang7"
$headers = @{
    Authorization = "Bearer $token"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# Repos to always skip (noise)
$skipList = @(
    "RoyZhang7/RoyZhang7",                        # profile repo
    "rahuldkjain/github-profile-readme-generator", # tool used once
    "portante/tufts-git",                          # minor touch
    "F-Stack/f-stack",                             # one-off
    "joseph-fox/python-bloomfilter",               # one-off
    "nslogx/Gitter",                               # one-off
    "Neet-Nestor/Telegram-Media-Downloader",       # one-off
    "gwdistsys18/dist-sys-practice",               # old course
    "docc-lab/tufts_cs_150_dcc",                   # course infra
    "docc-lab/tufts_cs_118",                       # course infra
    "docclab-docs/meeting_notes_vertical_tracing", # internal notes
    "docclab-docs/meeting_notes_perf_contention",  # internal notes
    "Tufts-CS-118/raft-container",                 # course infra
    "Tufts-CS-118/raft-autograder",                # course infra
    "Tufts-CS-118/gRPC-autograder",                # course infra
    "Tufts-CS-110/CPE-internal",                   # course infra
    "RS1999ent/shared_tracing_docs",               # internal docs
    "RoyZhang7/vertical-tracing-cases"             # private scratch
)

$repos = @{}
$counts = @{}

function Add-Count($repoName, $amount) {
    if (-not $counts.ContainsKey($repoName)) { $counts[$repoName] = 0 }
    $counts[$repoName] += $amount
}

# ============================================================
# METHOD 1: GraphQL contributionsCollection year by year
# Covers: all public + private repos you contributed to
# Limitation: does not count non-default branches
# ============================================================
Write-Host "`n[METHOD 1] GraphQL year-by-year scan..."

function Get-YearContribs($from, $to) {
    $q = '{ "query": "{ viewer { contributionsCollection(from: \"' + $from + '\", to: \"' + $to + '\") { commitContributionsByRepository(maxRepositories: 100) { contributions { totalCount } repository { nameWithOwner isPrivate } } pullRequestContributionsByRepository(maxRepositories: 100) { contributions { totalCount } repository { nameWithOwner isPrivate } } issueContributionsByRepository(maxRepositories: 100) { contributions { totalCount } repository { nameWithOwner isPrivate } } } } }" }'
    $q | Set-Content -Path "$env:TEMP\qyear.graphql" -Encoding ascii
    return gh api graphql --input "$env:TEMP\qyear.graphql" | ConvertFrom-Json
}

$currentYear = (Get-Date).Year
2015..$currentYear | ForEach-Object {
    $year = $_
    $from = "${year}-01-01T00:00:00Z"
    $to   = "${year}-12-31T23:59:59Z"
    Write-Host "  Fetching $year..."

    $result = Get-YearContribs $from $to
    $cc = $result.data.viewer.contributionsCollection

    @(
        $cc.commitContributionsByRepository
        $cc.pullRequestContributionsByRepository
        $cc.issueContributionsByRepository
    ) | ForEach-Object {
        $_ | ForEach-Object {
            if ($_.repository) {
                $name = $_.repository.nameWithOwner
                $repos[$name] = $_.repository.isPrivate
                Add-Count $name $_.contributions.totalCount
            }
        }
    }
}

# ============================================================
# METHOD 2: REST API org scan
# Covers: all repos under specified orgs including private ones
# More accurate commit counts (but still default branch only)
# Add orgs here as needed in the future
# ============================================================
Write-Host "`n[METHOD 2] REST API org scan..."

$orgs = @("docc-lab", "docclab-docs")

foreach ($org in $orgs) {
    $page = 1
    do {
        $url = "https://api.github.com/orgs/$org/repos?per_page=100&page=$page&type=all"
        try {
            $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
            $response | ForEach-Object {
                $repoFullName = $_.full_name
                $repos[$repoFullName] = $_.private
            }
            Write-Host "  Got $($response.Count) repos from $org page $page"
            $page++
        } catch {
            Write-Host "  ERROR fetching $org : $_"
            $response = @()
        }
    } while ($response.Count -eq 100)
}

# Count commits for org repos
foreach ($repo in ($repos.Keys | Where-Object { $_ -like "docc-lab/*" -or $_ -like "docclab-docs/*" })) {
    Write-Host "  Counting commits in $repo ..."
    $totalCommits = 0
    $page = 1
    do {
        $url = "https://api.github.com/repos/$repo/commits?author=$username&per_page=100&page=$page"
        try {
            $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
            $totalCommits += $response.Count
            $page++
        } catch {
            $response = @()
        }
    } while ($response.Count -eq 100)
    Add-Count $repo $totalCommits
}

# ============================================================
# OUTPUT: Filtered and ranked
# ============================================================
Write-Host "`n=== All contributed repos (filtered, ranked) ==="
$repos.GetEnumerator() |
    Where-Object { $_.Key -notin $skipList } |
    Where-Object { ($counts[$_.Key] ?? 0) -gt 0 } |
    Sort-Object { $counts[$_.Key] } -Descending |
    ForEach-Object {
        $visibility = if ($_.Value) { "PRIVATE" } else { "PUBLIC" }
        $count = $counts[$_.Key] ?? 0
        "{0,6} | {1} | {2}" -f $count, $visibility, $_.Key
    }
