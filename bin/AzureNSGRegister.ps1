<################################################################################
## @author:Yasutoshi Tamura
## @summary: Azure NSGのエクスポート/インポート
## @parameter
##  1:ConfigFileName：パラメータファイル名
## @return: 0:Success 1:Error 99:Exception
################################################################################>

param (
    [parameter(mandatory = $true)][string]$ConfigFileName,
    [switch]$ExportOnly = $false
)

function importNSG {
    param (
        $Settingjson,
        $Log,
        $returnCode,
        $ImportFilePath
    )
    $resultImportNSG = $returnCode.Success
    $InLayoutjson = $Settingjson.Layout | where { $_.in -ge 0 } | sort in
    $Importcsv = Import-Csv -Path $ImportFilePath -Delimiter $Settingjson.Import.csv.Delimiter -Encoding utf8 | where { $_.$($InLayoutjson.Title | sort in -top 1) -notmatch "^#" } #| sort $(($InLayoutjson | where { $_.NSGResource -eq $true -and $_.Resource -match "^Name" }).Title)

    if (!$Importcsv) {
        $Log.Error("ファイル「$($ImportFilePath)」の読込に失敗しました")
        return $returnCode.Error
    }

    # 列名の取得
    $NSGColumnName = $(($InLayoutjson | where { $_.NSGResource -eq $true -and $_.Resource -match "^Name" }).Title)
    $ResourceGroupColumnName = $(($InLayoutjson | where { $_.Resource -eq "ResourceGroupName" }).Title)
    $EntryTypeColumnName = $(($InLayoutjson | where { $_.Resource -eq "EntryType" }).Title)
    $DeleteCaption = ($Settingjson.Convert.EntryType | where { $_.DeleteRule -eq $true }).Caption

    $LogDirection = @{"Inbound" = "受信"; "Outbound" = "送信" }
    # 一意のNSG名を取得
    $UniqueNSGNames = ($Importcsv | where { $_.$NSGColumnName -notin ($null, "") } | where { $_.$ResourceGroupColumnName -notin ($null, "") } | sort $NSGColumnName -Unique).$NSGColumnName
    $Targetcsv = @($Importcsv | where { $_.$EntryTypeColumnName -eq ($Settingjson.Convert.EntryType | where { $_.DeleteRule -eq $true }).Caption }) + @($Importcsv | where { $_.$EntryTypeColumnName -eq ($Settingjson.Convert.EntryType | where { $_.DeleteRule -eq $false }).Caption })
    $Targetcsv = $Targetcsv | where { $_.$NSGColumnName -notin ($null, "") } | where { $_.$ResourceGroupColumnName -notin ($null, "") }

    foreach ($UniqueNSGName in $UniqueNSGNames) {
        $UpdateNSG = $false
        $Log.Info("NSG「$UniqueNSGName」のインポート処理を開始します。")
        $initImport = $true
        foreach ($csvLine in ($Targetcsv | where { $_.$NSGColumnName -eq $UniqueNSGName })) {
            # データ取得
            $ImportData = @{
                NSGName                              = $csvLine.$NSGColumnName
                ResourceGroupName                    = $csvLine.$ResourceGroupColumnName
                EntryType                            = $csvLine.$EntryTypeColumnName
                RuleName                             = $csvLine.$(($InLayoutjson | where { $_.NSGResource -eq $false -and $_.Resource -eq "Name" }).Title)
                Direction                            = $csvLine.$(($InLayoutjson | where { $_.Resource -eq "Direction" }).Title)
                Priority                             = $csvLine.$(($InLayoutjson | where { $_.Resource -eq "Priority" }).Title)
                SourceAddressPrefix                  = @($csvLine.$(($InLayoutjson | where { $_.Resource -eq "SourceAddressPrefix" }).Title).Split(","))
                SourceApplicationSecurityGroups      = $csvLine.$(($InLayoutjson | where { $_.Resource -eq "SourceApplicationSecurityGroups" }).Title)
                SourcePortRange                      = @($csvLine.$(($InLayoutjson | where { $_.Resource -eq "SourcePortRange" }).Title).Split(","))
                DestinationAddressPrefix             = @($csvLine.$(($InLayoutjson | where { $_.Resource -eq "DestinationAddressPrefix" }).Title).Split(","))
                DestinationApplicationSecurityGroups = $csvLine.$(($InLayoutjson | where { $_.Resource -eq "DestinationApplicationSecurityGroups" }).Title)
                DestinationPortRange                 = @($csvLine.$(($InLayoutjson | where { $_.Resource -eq "DestinationPortRange" }).Title).Split(","))
                Protocol                             = $csvLine.$(($InLayoutjson | where { $_.Resource -eq "Protocol" }).Title)
                Access                               = $csvLine.$(($InLayoutjson | where { $_.Resource -eq "Access" }).Title)
            }

            if ($initImport) {
                $ResourceGroup = Get-AzResourceGroup -Name $ImportData.ResourceGroupName
                $NSG = $null
                $NSG = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup.ResourceGroupName -Name $ImportData.NSGName
                $initImport = $false
            }
            if (!$NSG -and $ImportData.EntryType -eq $DeleteCaption) {
                $Log.Warn("NSG「$($ImportData.NSGName)」が存在しないため、$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の削除はスキップします。")
                continue
            }

            if (!$NSG) {
                $Log.Info("NSG「$($ImportData.NSGName)」を作成します。")
                $NSG = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup.ResourceGroupName -Name $ImportData.NSGName -Location $ResourceGroup.Location
                if (!$NSG) {
                    $Log.Error("NSG「$($ImportData.NSGName)」の作成に失敗しました。")
                    $UpdateNSG = $false
                    $resultImportNSG = $returnCode.Error
                    break
                }
                $Log.Info("NSG「$($ImportData.NSGName)」の作成に成功しました。")
            }

            $NSGRule = $null
            $NSGRule = Get-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName

            if ($ImportData.EntryType -eq $DeleteCaption) {
                $Log.Info("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の削除を開始します。")
                if (!$NSGRule) {
                    $Log.Warn("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」は存在しないため、スキップします。")
                    continue
                }
                $resultRemoveNSGRule = $null
                $resultRemoveNSGRule = Remove-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName

                if (!$resultRemoveNSGRule) {
                    $Log.Error("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の削除に失敗しました。")
                    $UpdateNSG = $false
                    $resultImportNSG = $returnCode.Error
                    break
                }

                $Log.Info("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の削除に成功しました。")
                $UpdateNSG = $true
                continue
            }

            if (!$NSGRule) {
                $Log.Info("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の追加を開始します。")
                $resultAddNSGRule = $null
                $resultAddNSGRule = setNWSecurityRule -NSG $NSG -ImportData $ImportData -Log $Log -AddRule 
                if (!$resultAddNSGRule) {
                    $Log.Error("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の追加に失敗しました。")
                    $UpdateNSG = $false
                    $resultImportNSG = $returnCode.Error
                    break
                }

                $Log.Info("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の追加に成功しました。")
                $UpdateNSG = $true
                continue
            }

            $Log.Info("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の更新を開始します。")
            $resultSetNSGRule = $null
            $resultSetNSGRule = setNWSecurityRule -NSG $NSG -ImportData $ImportData -Log $Log

            if (!$resultSetNSGRule) {
                $Log.Error("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の更新に失敗しました。")
                $UpdateNSG = $false
                $resultImportNSG = $returnCode.Error
                break
            }
            $Log.Info("$($LogDirection.$($ImportData.Direction))セキュリティ規則「$($ImportData.RuleName)」の更新に成功しました。")
            $UpdateNSG = $true
        }
        if ($UpdateNSG ) {
            $Log.Info("NSG「$($ImportData.NSGName)」のセキュリティ規則を更新します。")
            $resultNSG = $null
            $resultNSG = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $NSG
            if (!$resultNSG) {
                $Log.Error($error[0])
                $Log.Error("NSG「$($ImportData.NSGName)」のセキュリティ規則更新に失敗しました。")
                $resultImportNSG = $returnCode.Error
                continue
            }
            $Log.Info("NSG「$($ImportData.NSGName)」のセキュリティ規則更新に成功しました。")
        }

        $Log.Info("NSG「$UniqueNSGName」のインポート処理を終了します。")
        
    }

    return $resultImportNSG

}

function exportNSG {
    param (
        $Settingjson,
        $Log,
        $returnCode
    )

    $Log.Info("NSGのエクスポートを開始します。")
    $TimeStamp = Get-Date -Format "yyyyMMddHHmmss"

    if (!(Test-Path -Path $Settingjson.Export.Directory)) {
        $Log.Error("出力ディレクトリ「$($Settingjson.Export.Directory)」が存在しません。")
        return $returnCode.Error
    }

    $Log.info("出力可能な全てのNSGを取得します。")
    try {
        $NSGALL = Get-AzNetworkSecurityGroup
        $Log.info("NSG数：$($NSGALL.Count)")
        $Log.info("NSG：$($NSGALL.Name)")
        if (!$NSGALL) {
            $Log.info("出力可能なNSGが存在しないため、出力処理を終了します。")
            return $returnCode.Success
        }
    }
    catch {
        $Log.Error("NSGの取得に失敗しました。")
        $Log.Error($_.Exception)
        return $returnCode.Exception
    }
    $Log.Info("NSGの取得に成功しました。")
    

    $Log.info("全てのASGを取得します。")
    try {
        $ASGAll = Get-AzApplicationSecurityGroup
        $Log.info("ASG数：$($ASGAll.Count)")
        $Log.info("ASG：$($ASGAll.Name)")
    }
    catch {
        $Log.Error("ASGの取得に失敗しました。")
        $Log.Error($_.Exception)
        return $returnCode.Exception
    }
    $Log.info("ASGの取得に成功しました。")

    foreach ($NSG in $NSGALL) {
        $Log.Info("NSG「$($NSG.Name)」の定義出力を開始します。")

        $OutNSG = $null
        $OutLayoutjson = $Settingjson.Layout | where { $_.out -ge 0 } | sort out
        $OutNSG = $($OutLayoutjson.Title -join $Settingjson.Export.csv.Delimiter)

        foreach ($Rule in ($NSG.SecurityRules | sort Direction, Priority)) {
            $OutLine = @()
    
            foreach ($eachLayout in $OutLayoutjson) {
                $Column = $Rule
                if ($eachLayout.NSGResource) {
                    $Column = $NSG
                }

                $eachValue = $Column.$($eachLayout.Resource)
                
                if ($eachValue -and $eachLayout.Resource -match $asgColumName) {
                    $ASGName = ($ASGAll | where { $_.Id -eq $eachValue.Id }).Name
                    $eachValue = $ASGName
                }

                $OutLine += $eachValue -join ","
            }
            $OutNSG += "`n" + $($OutLine -join $Settingjson.Export.csv.Delimiter)

        }
        $OutFilePath = Join-Path $Settingjson.Export.Directory -ChildPath "$($NSG.Name)_${TimeStamp}_${PID}.csv"
        $OutNSG | Out-File -FilePath $OutFilePath -Encoding utf8
    
        $Log.Info("NSG「$($NSG.Name)」の定義出力が終了しました。")
    }

    $Log.Info("NSGのエクスポートが終了しました。")

    return $returnCode.Success
}

function setNWSecurityRule {
    param(
        $NSG,
        [hashtable] $ImportData,
        $Log,
        [switch]$AddRule = $false
    )

    $execType = [ExecAttributes]::Add -band $AddRule.ToBool()

    $sourceASG = $null
    if ($ImportData.SourceApplicationSecurityGroups) {
        $sourceASG = Get-AzApplicationSecurityGroup -Name $ImportData.SourceApplicationSecurityGroups
        if (!$sourceASG) {
            $Log.Error("SourceApplicationSecurityGroup「$($ImportData.SourceApplicationSecurityGroups)」の取得に失敗しました。")
            return $null
        }
        $execType += [ExecAttributes]::SourceASG
    }

    $destinationASG = $null
    if ($ImportData.DestinationApplicationSecurityGroups) {
        $destinationASG = Get-AzApplicationSecurityGroup -Name $ImportData.DestinationApplicationSecurityGroups
        if (!$destinationASG) {
            $Log.Error("DestinationApplicationSecurityGroup「$($ImportData.DestinationApplicationSecurityGroups)」の取得に失敗しました。")
            return $null
        }
        $execType += [ExecAttributes]::DestinationASG
    }

    # セキュリティ規則の追加/更新
    switch ($execType ) {
        ([ExecAttributes]::Add) {
            $resultNSGRule = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceAddressPrefix $ImportData.SourceAddressPrefix -SourcePortRange $ImportData.SourcePortRange -DestinationAddressPrefix $ImportData.DestinationAddressPrefix -DestinationPortRange $ImportData.DestinationPortRange
            continue
        }
        ([ExecAttributes]::Add + [ExecAttributes]::SourceASG) {
            $resultNSGRule = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceApplicationSecurityGroup $sourceASG -SourcePortRange $ImportData.SourcePortRange -DestinationAddressPrefix $ImportData.DestinationAddressPrefix -DestinationPortRange $ImportData.DestinationPortRange 
            continue
        }
        ([ExecAttributes]::Add + [ExecAttributes]::DestinationASG) {
            $resultNSGRule = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceAddressPrefix $ImportData.SourceAddressPrefix -SourcePortRange $ImportData.SourcePortRange -DestinationApplicationSecurityGroup $destinationASG -DestinationPortRange $ImportData.DestinationPortRange 
            continue
        }
        ([ExecAttributes]::Add + [ExecAttributes]::SourceASG + [ExecAttributes]::DestinationASG) {
            $resultNSGRule = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceApplicationSecurityGroup $sourceASG -SourcePortRange $ImportData.SourcePortRange -DestinationApplicationSecurityGroup $destinationASG -DestinationPortRange $ImportData.DestinationPortRange
            continue
        }
        ([ExecAttributes]::None) {
            $resultNSGRule = Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceAddressPrefix $ImportData.SourceAddressPrefix -SourcePortRange $ImportData.SourcePortRange -DestinationAddressPrefix $ImportData.DestinationAddressPrefix -DestinationPortRange $ImportData.DestinationPortRange -SourceApplicationSecurityGroup @() -DestinationApplicationSecurityGroup @()
            continue
        }
        ([ExecAttributes]::SourceASG) {
            $resultNSGRule = Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceApplicationSecurityGroup $sourceASG -SourcePortRange $ImportData.SourcePortRange -DestinationAddressPrefix $ImportData.DestinationAddressPrefix -DestinationPortRange $ImportData.DestinationPortRange -DestinationApplicationSecurityGroup @()
            continue
        }
        ([ExecAttributes]::DestinationASG) {
            $resultNSGRule = Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceAddressPrefix $ImportData.SourceAddressPrefix -SourcePortRange $ImportData.SourcePortRange -DestinationApplicationSecurityGroup $destinationASG -DestinationPortRange $ImportData.DestinationPortRange -SourceApplicationSecurityGroup @() 
            continue
        }
        ([ExecAttributes]::SourceASG + [ExecAttributes]::DestinationASG) {
            $resultNSGRule = Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $NSG -Name $ImportData.RuleName -Priority $ImportData.Priority -Direction $ImportData.Direction -Access $ImportData.Access -Protocol $ImportData.Protocol -SourceApplicationSecurityGroup $sourceASG -SourcePortRange $ImportData.SourcePortRange -DestinationApplicationSecurityGroup $destinationASG -DestinationPortRange $ImportData.DestinationPortRange
            continue
        }
    }

    return $resultNSGRule
}

[Flags()] enum ExecAttributes {
    None = 0
    Add = 1
    SourceASG = 2
    DestinationASG = 4
    All = 7
}

####### メイン処理 #######
# スクリプト格納ディレクトリを取得
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent

# モジュールのロード
. (Join-Path $scriptDir -childPath "LogController.ps1")


# エラー、リターンコード設定
$error.Clear()
Set-Variable -Name returnCode -Value @{Success = 0; Error = 1; Exception = 99 } -Option Constant
Set-Variable -Name asgColumName -Value "ApplicationSecurityGroups" -Option Constant
# 警告の表示抑止
Set-Item -Path Env:\SuppressAzurePowerShellBreakingChangeWarnings -Value "true"

# LogController オブジェクト生成
if ($Stdout) {
    $Log = New-Object LogController
}
else {
    $LogFilePath = Split-Path $scriptDir -Parent | Join-Path -ChildPath log -Resolve
    $LogFile = (Get-ChildItem $MyInvocation.MyCommand.Path).BaseName + ".log"
    $Log = New-Object LogController($(Join-Path $LogFilePath -ChildPath $LogFile), $false)
}

try {

    $SettingFileDir = Split-Path $MyInvocation.MyCommand.Path -Parent | Split-Path -Parent | Join-Path -ChildPath etc -Resolve
    $SettingFilePath = Join-Path -Path $SettingFileDir -ChildPath $ConfigFileName
    
    # 設定ファイル存在確認
    if (!(Test-Path $SettingFilePath)) {
        $Log.Error("${SettingFilePath}が存在しません")
        Exit $returnCode.Error
    }
    
    # 設定ファイルの読込
    $Settingjson = Get-Content $SettingFilePath | ConvertFrom-Json

    $Log.info("設定ファイル「${ConfigFileName}」")

    # Export列順の重複チェック
    $DuplicateExportOrder = $Settingjson.Layout | where { $_.out -ge 0 } | Group-Object out | where { $_.Count -gt 1 }
    if ($DuplicateExportOrder) {
        $Log.Error("設定ファイル：Layout.outの値「$($DuplicateExportOrder.Name -join ",")」が重複しています。", $returnCode.Error)
        exit $returnCode.Error
    }

    if (!$ExportOnly) {
        # Import列順の重複チェック
        $DuplicateImportOrder = $Settingjson.Layout | where { $_.in -ge 0 } | Group-Object in | where { $_.Count -gt 1 }
        if ($DuplicateImportOrder) {
            $Log.Error("設定ファイル：Layout.inの値「$($DuplicateImportOrder.Name -join ",")」が重複しています。", $returnCode.Error)
            exit $returnCode.Error
        }
    
        [void][System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms")

        $Dialog = New-Object System.Windows.Forms.OpenFileDialog
        $Dialog.Filter = "CSVファイル(*.csv)|*.csv"
        $Dialog.InitialDirectory = $Settingjson.Import.InitialDirectory
        $Dialog.Title = "ファイルを選択してください"
        $Dialog.Multiselect = $true
    
        # ダイアログを表示
        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Cancel) {
            $Log.info("Cancelが選択されたため、処理を終了します。")
            exit $returnCode.Success
        }
    }

    # Azureログイン
    $LoginInfo = Login-AzAccount -Subscription $Settingjson.Azure.SubscriptionID

    if (!$LoginInfo) {
        $Log.Error("Azureのログインに失敗しました。サブスクリプションID：$($Settingjson.Azure.SubscriptionID)", $returnCode.Error)
        exit $returnCode.Error
    }

    $resultExport = exportNSG -Settingjson $Settingjson -Log $Log -returnCode $returnCode

    # エクスポートに失敗した場合、中断
    if ($resultExport -ne $returnCode.Success) {
        $Log.Error("NSGのエクスポートに失敗しました", $returnCode.Error)
        exit $returnCode.Error
    }

    # エクスポートのみの場合処理終了
    if ($ExportOnly) {
        $Log.Info("オプション「-ExportOnly」を指定しているため、処理を終了します。", $returnCode.Success)
        exit $returnCode.Success
    }

    # インポート処理
    $resultNSGRegister = $returnCode.Success
    foreach ($ImportFilePath in $Dialog.FileNames) {
        $Log.Info("ファイル「$((Get-ChildItem $ImportFilePath).Name)」の読込を開始します。")
        $resultImport = importNSG -Settingjson $Settingjson -Log $Log -returnCode $returnCode -ImportFilePath $ImportFilePath
        $Log.Info("ファイル「$((Get-ChildItem $ImportFilePath).Name)」の読込が終了しました。")
        $resultNSGRegister = $resultNSGRegister -bor $resultImport
    }

}
#################################################
# エラーハンドリング
#################################################
catch {
    $Log.Error("予期しないエラーが発生しました。")
    $Log.Error($_.Exception, $returnCode.Exception)
    exit $returnCode.Exception
}

$Log.Info("全ての処理が終了しました。", $resultNSGRegister)
exit $resultNSGRegister
