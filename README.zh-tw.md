# AWS CloudFront IP 自動更新 Cloud Armor 工具

此專案提供一個 AWS Lambda 函數，設計用於自動以最新的 CloudFront IP 範圍更新 Google Cloud Armor 安全政策。它確保您的 GCP 基礎設施能夠透過動態調整 IP 變更來保持受保護狀態。

## 背景

### AWS ip-ranges.json 概覽

AWS 以 JSON 格式發佈其當前 IP 地址範圍，可在 [https://ip-ranges.amazonaws.com/ip-ranges.json](https://ip-ranges.amazonaws.com/ip-ranges.json) 獲取。此文件包含特定 AWS 服務和地區使用的 IP 範圍。

文件中的每個條目包括：

- `ip_prefix`：CIDR 範圍
- `region`：相關的 AWS 地區
- `service`：使用該 IP 的 AWS 服務（例如 `CLOUDFRONT_ORIGIN_FACING`、`EC2`）
- `network_border_group`：IP 廣告的範圍

此解決方案過濾 `CLOUDFRONT_ORIGIN_FACING` 條目並僅使用這些 CIDR，讓你能精細控制允許通過 GCP Cloud Armor 的 AWS 流量。

更多資訊，請參閱 [AWS IP 地址範圍文檔](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-ranges.html)。

### GCP Armor 限制

Google Cloud Armor 提供命名 IP 地址列表，如 `iplist-public-clouds-aws`，代表 AWS 使用的整個公共 IP 空間。雖然方便，但這種方法缺乏精細度。如果你的目標是只允許 CloudFront 流量，使用 AWS 命名列表也會包括來自 EC2、Lambda 或 RDS 等服務的流量，可能增加你的攻擊面。

此解決方案通過動態獲取並僅應用 CloudFront IP 範圍到你的 Cloud Armor 策略來解決這個問題，確保更嚴格和更具體的訪問控制。

## 功能特點

- **自動更新**：獲取最新的 CloudFront IP 範圍並相應地更新 GCP Cloud Armor 政策。
- **規則管理**：將 IP 分組成區塊（例如，每條規則 10 個）以符合 GCP 限制。
- **安全規則替換**：僅識別並替換先前由此 Lambda 添加的規則，保留其他自定義規則。
- **安全憑證處理**：利用 AWS Secrets Manager 安全地存儲和訪問 GCP 服務帳戶憑證。
- **事件驅動執行**：當 CloudFront IP 範圍變更時由 AWS SNS 通知觸發。[AWS 文檔 - AWS IP 地址範圍通知](https://docs.aws.amazon.com/vpc/latest/userguide/subscribe-notifications.html)

## 架構

_本節將包含圖表以說明此解決方案的架構。_

![架構圖](architecture-diagram.png)

## 運作原理

此解決方案設計為與現有的 Cloud Armor 規則共存。它專門管理與 AWS CloudFront IP 範圍相關的規則，不會觸及其他規則。

Lambda 函數通過查找 `description` 欄位中的特定前綴（例如 `(Managed by AWS Lambda) CloudFront IPs chunk`）來識別它創建的規則。這使系統能夠安全地僅刪除這些條目並用最新版本替換它們。

此解決方案不依賴 DynamoDB 或 S3 進行狀態跟踪。相反，Lambda 函數：

1. 從 AWS 的 [ip-ranges.json](https://ip-ranges.amazonaws.com/ip-ranges.json) 獲取當前的 CloudFront IP 範圍列表。
2. 將 IP 聚合並分組成每個 Cloud Armor 規則最多 10 個 CIDR 的區塊。
3. 使用 GCP API 獲取現有的 Cloud Armor 政策。
4. 刪除先前由 Lambda 創建的所有規則（通過特定描述前綴識別）。
5. 使用聚合的 CloudFront CIDR 創建一組新的規則。
6. 使用 `patch` API 呼叫向 Google Cloud Armor 一次性提交所有更改，確保立即應用。

這種設計允許完全無狀態操作，可由事件或手動觸發，並且始終生成完整的最新政策，無需中間存儲。

## 前提條件

### AWS

- **Secrets Manager**：在 AWS Secrets Manager 中存儲您的 GCP 服務帳戶 JSON 憑證。
- **S3 存儲桶**：用於存儲打包的 Lambda Layer ZIP 文件的 S3 存儲桶。
- **IAM 角色**：具有執行 Lambda 函數和訪問 Secrets Manager 權限的 IAM 角色。

### GCP

- **服務帳戶**：創建具有以下角色的 GCP 服務帳戶：
  - **`roles/compute.securityAdmin`**：允許管理 Cloud Armor 安全政策。

- **Cloud Armor 安全政策**：確保您配置中指定的 Google Cloud Armor 安全政策已經存在。

- **啟用 API**：
  - 必須啟用 **Compute Engine API**。您可以通過控制台或 CLI 啟用它：
    - 控制台：[啟用 Compute Engine API](https://console.developers.google.com/apis/api/compute.googleapis.com/overview)
    - CLI：
      ```bash
      gcloud config set project YOUR_PROJECT_ID
      gcloud services enable compute.googleapis.com
      ```

## 部署步驟

1. **克隆存儲庫**：
   ```bash
   git clone https://github.com/yourusername/gcp-cloudarmor-updater.git
   cd gcp-cloudarmor-updater
   ```

2. **打包 Lambda Layer**：
   使用提供的 shell 腳本將必要的 Python 依賴項打包成 Lambda Layer。
   ```bash
   sh ./scripts/package_layer.sh
   ```

3. **上傳 Layer 到 S3**：
   ```bash
   aws s3 cp layer.zip s3://your-s3-bucket-name/path/to/layer.zip
   ```

4. **部署 CloudFormation 堆疊**：
   ```bash
   aws cloudformation deploy \
     --template-file cloudformation.yaml \
     --stack-name gcp-cloudarmor-updater \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides \
       GCPServiceAccountSecretName=YourSecretName \
       GCPArmorPolicyName=YourPolicyName \
       GCPArmorRulePriority=1000 \
       LayerS3Bucket=your-s3-bucket-name \
       LayerS3Key=path/to/layer.zip
   ```

5. **填充 Secrets Manager**：

   使用 AWS CLI 將您的 GCP 服務帳戶 JSON 憑證存儲在 AWS Secrets Manager 中，名稱為 `GCPServiceAccountSecretName` 中指定的名稱：

   ```bash
   aws secretsmanager create-secret \
     --name YourSecretName \
     --secret-string file://path/to/your-gcp-credentials.json
   ```

   將 `YourSecretName` 替換為您在部署參數中指定的名稱，將 `path/to/your-gcp-credentials.json` 替換為您下載的 GCP JSON 憑證的路徑。

6. **測試 Lambda 函數並初始設置 Cloud Armor 中的規則**：
   ```bash
   aws lambda invoke \
     --function-name GCPArmorUpdater \
     --payload '{}' \
     response.json
   ```

## 打包 Lambda Layer

`scripts/package_layer.sh` 腳本自動創建包含必要 Python 依賴項的 Lambda Layer。

在運行此腳本之前，請確保您的環境中已安裝並可訪問 `pip`。

## 貢獻

我們歡迎社區貢獻！請參閱 [CONTRIBUTING.md](CONTRIBUTING.md) 了解指南。

## 安全

有關更多信息，請參閱 [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications)。

## 許可證

此庫根據 MIT-0 許可證授權。請參閱 [LICENSE](LICENSE) 文件。