function Get-StartupProgress([string]$Text) {
    $lines=@($Text -split '\r?\n' | Where-Object {$_ -match 'checking .*gguf:|gguf:.*GB|MTP draft layer:|mtp.layers|mtp_fetch|reading the model|still starting|Fetching the ready-made|pip install'})
    if(!$lines.Count){return '環境の準備・SSH接続'}
    $line=$lines[-1].Trim() -replace '^\[manager\]\s*',''
    $stage=if($line -match 'checking .*gguf:'){'モデルの整合性検証'}elseif($line -match 'gguf:.*GB'){'モデルをダウンロード'}elseif($line -match 'reading the model|still starting'){'モデルをメモリに読み込み'}elseif($line -match 'mtp.layers.*(q2_0|BF16|F32)'){'MTPの変換（数分かかります）'}elseif($line -match 'MTP draft|mtp.layers|mtp_fetch'){'MTPを取得・準備'}else{'推論エンジン・依存環境の準備'}
    $part=if($line -match '-0000([12])-of-00002'){' / ファイル '+$Matches[1]+'/2'}else{''}
    $pct=if($line -match '\((\d+)%\)'){' / この工程 '+$Matches[1]+'%'}else{''}
    return $stage+$part+$pct
}
