from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one match in {path}: {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


root = Path(__file__).resolve().parents[2]
installer = root / "install-release-v2.ps1"

replace_once(
    installer,
    '''function Get-ReleaseMetadata {
    $headers = @{ 'User-Agent' = 'SIRK-Updater-Installer-v2' }
    if ($Version) {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Eris92/SIRK-Updater/releases/tags/$tag"
    }
    return Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/Eris92/SIRK-Updater/releases/latest'
}''',
    '''function Get-GitHubApiHeaders {
    $headers = @{
        'User-Agent' = 'SIRK-Updater-Installer-v2'
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $token = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $env:GITHUB_TOKEN.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $env:GH_TOKEN.Trim()
    }
    else {
        ''
    }
    if ($token) { $headers.Authorization = "Bearer $token" }
    return $headers
}

function Get-ReleaseMetadata {
    $headers = Get-GitHubApiHeaders
    if ($Version) {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Eris92/SIRK-Updater/releases/tags/$tag"
    }
    return Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/Eris92/SIRK-Updater/releases/latest'
}'''
)

print("GitHub API authentication support applied to release installer.")
