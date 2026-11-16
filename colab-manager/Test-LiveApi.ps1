param([string]$BaseUrl='http://127.0.0.1:8080')
$ErrorActionPreference='Stop'
$health=Invoke-RestMethod "$BaseUrl/health" -TimeoutSec 15
if(!$health.loaded -or $health.max_context -ne 32768){throw 'Expected loaded 32K model'}
function Chat($messages,$tools=$null) {
    $body=@{model=$health.model;messages=$messages;max_tokens=1024;temperature=0;stream=$false;chat_template_kwargs=@{enable_thinking=$false}}
    if($tools){$body.tools=$tools}
    Invoke-RestMethod "$BaseUrl/v1/chat/completions" -Method Post -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 15) -TimeoutSec 180
}
$simple=Chat @(@{role='user';content='Reply with exactly: STRATA_READY'})
if($simple.choices[0].message.content -notmatch 'STRATA_READY'){throw 'Simple response failed'}
$probe=Join-Path $PSScriptRoot 'state/api-local-probe.txt'
$marker='LOCAL_PROBE_'+[guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($probe,$marker)
$messages=@(@{role='user';content='Call read_local_probe to read the local probe file, then reply with its exact contents.'})
$tools=@(@{type='function';function=@{name='read_local_probe';description='Read the probe file on the local Windows PC.';parameters=@{type='object';properties=@{};required=@()}}})
$first=Chat $messages $tools
$msg=$first.choices[0].message
if(!$msg.tool_calls -or $msg.tool_calls[0].function.name -ne 'read_local_probe'){throw 'Expected tool call'}
# File access is executed here on Windows; only the tool result goes to Colab.
$value=[IO.File]::ReadAllText($probe)
$messages+=@{role='assistant';content=$msg.content;tool_calls=$msg.tool_calls}
$messages+=@{role='tool';tool_call_id=$msg.tool_calls[0].id;content=$value}
$last=Chat $messages $tools
if($last.choices[0].message.content -notmatch [regex]::Escape($marker)){throw 'Tool result roundtrip failed'}
@{at=[DateTime]::UtcNow.ToString('o');model=$health.model;context=$health.max_context;response='PASS';localFileToolRoundtrip='PASS'}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'state/live-api-validation.json')
'PASS: loaded 32K model, response, API tool call with local Windows file read'
