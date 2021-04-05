# Azure-NSGRegister
# 概要
Azure NSGの設定をcsvファイルからインポート、csvファイルへのエクスポートをします。  
スクリプト実行時に以下を指定できます。  

- インポートファイルはダイアログで複数指定出来ます。
- エクスポートのみの実行も可能です。

セキュリティルールの削除は可能ですが、NSGそのものを削除することはできません。  
同一NSGの指定で登録と削除が混在している場合、削除処理を先に実行します。  
Application Security Groupは対応していません。  

# 動作確認環境
PowerShell 7.1.3  
Azure PowerShell 5.7.0

# 準備
## コンフィグファイルの設定
コンフィグファイル（サンプルではSetting.json）に値を入力します。

- Azure
    - TenantID
        - 接続するテナントID
    - SubscriptionID
        - 接続するサブスクリプションID
- Convert
    - EntryType
        - インポートファイルで指定するNSGの登録（更新）、または削除の文言  
        削除の文言には`DeleteRule`を`true`にします。 
- Import
    - InitialDirectory
        - インポートファイル選択ダイアログの初期ディレクトリ
    - Delimiter
        - 区切り文字
- Export
    - Directory
        - エクスポートするファイルの出力ディレクトリ
    - Delimiter
        - 区切り文字
- Layout  
    - Title
        - インポート/エクスポートのヘッダ
    - Resource
        - Azureリソース名（変更不可）
    - in
        - インポートファイルの列順  
    - out
        - エクスポートファイルの列順  
        出力しない項目は-1以下を指定してください。
    - NSGResource
        - NSG名とResourceGroup名には`true`を指定してください。  

# 使い方
## オプション

**-ConfigFileName** <コンフィグファイル名>  
.\etc配下のコンフィグファイル名を指定します。  

**[ -ExportOnly ]**  
NSGのエクスポートのみ実行したい場合指定します。  

## インポートファイルの準備
UTF8で記述ください。  
先頭文字が`#`の場合、スキップします。  

## 実行例
AzureNSGRegister.ps1 -ConfigFileName Setting.json