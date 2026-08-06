[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$image = 'jenkins-platform/build-agent:node20'
$casePrefix = "jenkins-platform-profile-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) $casePrefix
$mockRoot = Join-Path $tempRoot 'mock-bin'
$stateRoot = Join-Path $tempRoot 'state'
$secretRoot = Join-Path $tempRoot 'secrets'
$utf8 = [Text.UTF8Encoding]::new($false)

New-Item -ItemType Directory -Path $mockRoot, $stateRoot, $secretRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $secretRoot 'jenkins_admin_password'), "admin-test-secret`n", $utf8)
[IO.File]::WriteAllText((Join-Path $secretRoot 'jenkins_audit_password'), "audit-test-secret`n", $utf8)

$dockerMock = @'
#!/usr/bin/env bash
set -euo pipefail
state=${MOCK_STATE:?}
printf 'docker %s\n' "$*" >>"$state/docker.log"

if [ "${1:-}" = compose ]; then
    shift
    while [ "${1:-}" = -f ]; do shift 2; done
    if [ "${1:-}" = ps ] && [ "${2:-}" = --quiet ]; then
        service=${3:?}
        [ -f "$state/$service.running" ] && printf '%s-id\n' "$service"
        exit 0
    fi
    if [ "${1:-}" = --profile ]; then
        shift 2
    fi
    case "${1:-}" in
        up)
            shift
            [ "${1:-}" = --detach ] && shift
            for service in "$@"; do
                : >"$state/$service.running"
                : >"$state/$service.healthy"
            done
            ;;
        stop)
            shift
            for service in "$@"; do
                rm -f -- "$state/$service.running" "$state/$service.healthy"
                case "$service" in *-agent) rm -f -- "$state/node.online" ;; esac
            done
            ;;
        *) printf 'Unsupported mock compose command: %s\n' "$*" >&2; exit 64 ;;
    esac
    exit 0
fi

if [ "${1:-}" = inspect ]; then
    shift
    [ "${1:-}" = --format ] || exit 64
    format=${2:?}
    id=${3:?}
    service=${id%-id}
    case "$format" in
        *State.Running*) [ -f "$state/$service.running" ] && printf 'true\n' || printf 'false\n' ;;
        *) [ -f "$state/$service.healthy" ] && printf 'healthy\n' || printf 'starting\n' ;;
    esac
    exit 0
fi

printf 'Unsupported mock docker command: %s\n' "$*" >&2
exit 64
'@

$curlMock = @'
#!/usr/bin/env bash
set -euo pipefail
state=${MOCK_STATE:?}
netrc=''
output=''
url=''
method=GET
while [ "$#" -gt 0 ]; do
    case "$1" in
        --netrc-file) netrc=$2; shift 2 ;;
        --cookie-jar|--cookie|--header) shift 2 ;;
        --request) method=$2; shift 2 ;;
        -o) output=$2; shift 2 ;;
        --globoff|--fail|--silent|--show-error) shift ;;
        http://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[ -n "$url" ] || { printf 'Mock curl did not receive a URL.\n' >&2; exit 64; }
actor=$(sed -n 's/.* login \([^ ]*\) password .*/\1/p' "$netrc")
case "$url" in
    */queue/api/json*) endpoint=queue ;;
    */computer/api/json*) endpoint=executors ;;
    */crumbIssuer/*) endpoint=crumb ;;
    */launchSlaveAgent) endpoint=launch ;;
    */computer/*/api/json*) endpoint=node ;;
    *) endpoint=unknown ;;
esac
printf 'actor=%s method=%s endpoint=%s\n' "$actor" "$method" "$endpoint" >>"$state/curl.log"

case "$endpoint" in
    queue)
        if [ -f "$state/queue.busy" ]; then body='{"items":[{"id":1}]}'; else body='{"items":[]}'; fi
        ;;
    executors)
        if [ -f "$state/executor.busy" ]; then
            body='{"computer":[{"executors":[{"currentExecutable":{"url":"job/1"}}],"oneOffExecutors":[]}]}'
        else
            body='{"computer":[{"executors":[{"currentExecutable":null}],"oneOffExecutors":[]}]}'
        fi
        ;;
    crumb) body='Jenkins-Crumb:test-crumb' ;;
    launch)
        [ "$actor" = admin ] || exit 77
        [ -f "$state/launch.fail" ] || : >"$state/node.online"
        body=''
        ;;
    node)
        if [ -f "$state/node.online" ]; then body='{"offline":false}'; else body='{"offline":true}'; fi
        ;;
    *) printf 'Unsupported mock curl endpoint: %s\n' "$url" >&2; exit 64 ;;
esac

if [ -n "$output" ]; then
    printf '%s' "$body" >"$output"
else
    printf '%s' "$body"
fi
'@

$flockMock = @'
#!/usr/bin/env bash
set -euo pipefail
state=${MOCK_STATE:?}
printf 'flock %s\n' "$*" >>"$state/flock.log"
[ ! -f "$state/flock.busy" ]
'@

[IO.File]::WriteAllText((Join-Path $mockRoot 'docker'), $dockerMock, $utf8)
[IO.File]::WriteAllText((Join-Path $mockRoot 'curl'), $curlMock, $utf8)
[IO.File]::WriteAllText((Join-Path $mockRoot 'flock'), $flockMock, $utf8)

function Reset-State {
    Get-ChildItem -LiteralPath $stateRoot -Force | Remove-Item -Force
}

function Set-ServiceRunning {
    param([Parameter(Mandatory)][string]$Service)
    [IO.File]::WriteAllText((Join-Path $stateRoot "$Service.running"), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $stateRoot "$Service.healthy"), '', $utf8)
}

function Invoke-ProfileCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][int]$ExpectedExit
    )
    $containerName = "$casePrefix-$Name"
    $arguments = @(
        'run', '--rm', '--name', $containerName,
        '--network', 'none', '--read-only', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges',
        '--tmpfs', '/tmp:rw,exec,nosuid,nodev,size=16m',
        '--volume', "${repoRoot}:/opt/jenkins-platform:ro",
        '--volume', "${secretRoot}:/opt/jenkins-platform/.secrets:ro",
        '--volume', "${mockRoot}:/mock-source:ro",
        '--volume', "${stateRoot}:/state",
        '--env', 'MOCK_STATE=/state',
        '--env', 'PAPER_SERVER_PROFILE_POLL_ATTEMPTS=2',
        '--env', 'PAPER_SERVER_PROFILE_POLL_SECONDS=0',
        '--entrypoint', 'bash', $image,
        '-lc', 'mkdir -p /tmp/mock-bin; cp /mock-source/docker /mock-source/curl /mock-source/flock /tmp/mock-bin/; chmod 0700 /tmp/mock-bin/docker /tmp/mock-bin/curl /tmp/mock-bin/flock; export PATH="/tmp/mock-bin:$PATH"; exec bash /opt/jenkins-platform/scripts/paper-server-profile.sh "$@"',
        'profile-test', $Action, $Profile
    )
    $output = & docker @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $ExpectedExit) {
        throw "Profile case '$Name' exited $exitCode, expected $ExpectedExit. Output: $($output -join "`n")"
    }
    $residue = docker ps -a --filter "name=^/${containerName}$" --format '{{.Names}}'
    if ($LASTEXITCODE -ne 0 -or $residue) { throw "Profile case '$Name' left a test container." }
    return ($output -join "`n")
}

try {
    Reset-State
    [IO.File]::WriteAllText((Join-Path $stateRoot 'flock.busy'), '', $utf8)
    $output = Invoke-ProfileCase -Name lock -Action start -Profile regression -ExpectedExit 79
    Assert-True ($output -match 'reason=lifecycle_lock') 'A concurrent lifecycle invocation is rejected before Docker mutation.'

    Reset-State
    $output = Invoke-ProfileCase -Name start -Action start -Profile regression -ExpectedExit 0
    Assert-True ($output -match 'PROFILE_LIFECYCLE_EVIDENCE profile=regression action=start containers=2 node=online started=1 residue=0 status=OK') 'Fresh start reaches healthy containers and an online Jenkins node.'
    Assert-True ((Test-Path (Join-Path $stateRoot 'regression-agent.running')) -and (Test-Path (Join-Path $stateRoot 'regression-docker.running'))) 'Fresh start runs only the requested Agent and DIND.'
    $curlLog = Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'curl.log')
    Assert-True ($curlLog -match 'actor=admin method=POST endpoint=launch') 'Node reconnect uses the existing administrator endpoint.'

    Reset-State
    Set-ServiceRunning release-agent
    Set-ServiceRunning release-docker
    $output = Invoke-ProfileCase -Name conflict -Action start -Profile regression -ExpectedExit 79
    Assert-True ($output -match 'reason=other_heavy_profile') 'Start refuses another running heavy profile.'
    Assert-True (-not (Test-Path (Join-Path $stateRoot 'regression-agent.running'))) 'Conflict refusal does not start the requested profile.'

    Reset-State
    Set-ServiceRunning regression-agent
    $output = Invoke-ProfileCase -Name partial -Action start -Profile regression -ExpectedExit 70
    Assert-True ($output -match 'reason=partial_profile_state') 'Start fails closed on a partial target profile.'

    Reset-State
    [IO.File]::WriteAllText((Join-Path $stateRoot 'launch.fail'), '', $utf8)
    $output = Invoke-ProfileCase -Name rollback -Action start -Profile regression -ExpectedExit 70
    Assert-True ($output -match 'reason=jenkins_node_online') 'Start reports a bounded Jenkins node timeout.'
    Assert-True ($output -match 'PROFILE_LIFECYCLE_CLEANUP profile=regression action=start containers=0 residue=0 status=OK') 'Failed fresh start rolls back its exact Agent and DIND.'
    Assert-True (-not (Test-Path (Join-Path $stateRoot 'regression-agent.running')) -and -not (Test-Path (Join-Path $stateRoot 'regression-docker.running'))) 'Failed start leaves no running profile services.'

    Reset-State
    Set-ServiceRunning regression-agent
    Set-ServiceRunning regression-docker
    [IO.File]::WriteAllText((Join-Path $stateRoot 'node.online'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $stateRoot 'queue.busy'), '', $utf8)
    $output = Invoke-ProfileCase -Name queue -Action stop -Profile regression -ExpectedExit 79
    Assert-True ($output -match 'reason=jenkins_queue count=1') 'Stop refuses a non-empty Jenkins queue.'
    Assert-True (Test-Path (Join-Path $stateRoot 'regression-agent.running')) 'Queue refusal preserves the running target profile.'

    Reset-State
    Set-ServiceRunning regression-agent
    Set-ServiceRunning regression-docker
    [IO.File]::WriteAllText((Join-Path $stateRoot 'node.online'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $stateRoot 'executor.busy'), '', $utf8)
    $output = Invoke-ProfileCase -Name executor -Action stop -Profile regression -ExpectedExit 79
    Assert-True ($output -match 'reason=active_executor count=1') 'Stop refuses an active Jenkins executor.'

    Reset-State
    Set-ServiceRunning regression-agent
    Set-ServiceRunning regression-docker
    [IO.File]::WriteAllText((Join-Path $stateRoot 'node.online'), '', $utf8)
    $output = Invoke-ProfileCase -Name stop -Action stop -Profile regression -ExpectedExit 0
    Assert-True ($output -match 'PROFILE_LIFECYCLE_EVIDENCE profile=regression action=stop containers=0 node=offline residue=0 status=OK') 'Idle stop reaches stopped containers and an offline Jenkins node.'
    $curlLog = Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'curl.log')
    Assert-True ($curlLog -match 'actor=audit method=GET endpoint=queue' -and $curlLog -match 'actor=audit method=GET endpoint=executors') 'Stop uses audit only for queue and executor checks.'
    Assert-True ($curlLog -notmatch 'actor=audit .*endpoint=(node|launch|crumb)') 'Audit is never used for node status or reconnect.'

    Reset-State
    $output = Invoke-ProfileCase -Name status -Action status -Profile deploy-test -ExpectedExit 0
    Assert-True ($output -match 'profile=deploy-test action=status containers=0 node=offline other_containers=0 residue=0 status=OK') 'Status reports a fully stopped profile without mutation.'

    $allLogs = (Get-ChildItem -LiteralPath $stateRoot -Filter '*.log' | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
    Assert-True ($allLogs -notmatch '(?i)down\s+--volumes|system\s+prune|volume\s+prune') 'Lifecycle tests contain no destructive global cleanup command.'

    $containers = docker ps -a --filter "name=$casePrefix" --format '{{.Names}}'
    Assert-True (-not $containers) 'Dockerized lifecycle tests leave zero containers.'
    Write-Host 'PROFILE_LIFECYCLE_TEST_EVIDENCE cases=9 containers=0 status=OK'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
