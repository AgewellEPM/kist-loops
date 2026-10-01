# Windows Terminal / PowerShell entry point for a LINUX Kist bundle under existing WSL2.
# No VM, distro, model or paid provider is started until the user opens this launcher.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'Kist requires an existing WSL2 Linux installation. Native Windows is not supported.'
}
$linuxRepo = (& wsl.exe --exec wslpath -a -- (Get-Location).Path)
if ($LASTEXITCODE -ne 0) { throw 'Cannot access this repo from the default WSL distro.' }
$linuxBundle = (& wsl.exe --exec wslpath -a -- $PSScriptRoot)
if ($LASTEXITCODE -ne 0) { throw 'Cannot access the Kist bundle from WSL.' }
# Pass user arguments as encoded JSON instead of embedding them in shell commands.
$payload = @{bundle=$linuxBundle.Trim(); repo=$linuxRepo.Trim(); arguments=@($args)} | ConvertTo-Json -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
$code = "import base64,json,os,subprocess,sys; from pathlib import Path; d=json.loads(base64.b64decode(sys.argv[1])); p=Path(d['bundle']); m=json.loads((p/'manifest.json').read_text()); assert m['target'].startswith('linux-'), 'Windows needs the Linux Kist bundle'; os.chdir(d['repo']); os.execv('/bin/sh',['sh',str(p/'kist'),*d['arguments']])"
& wsl.exe --exec python3 -c $code $encoded
exit $LASTEXITCODE
