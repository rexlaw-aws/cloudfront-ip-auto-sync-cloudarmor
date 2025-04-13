# AWS CloudFront IP 自动更新 Cloud Armor 工具

本项目提供了一个 AWS Lambda 函数，旨在自动使用最新的 CloudFront IP 范围更新 Google Cloud Armor 安全策略。它通过动态调整 IP 变化来确保您的 GCP 基础设施受到保护。

## 功能特点

- **自动更新**：获取最新的 CloudFront IP 范围并相应地更新 GCP Cloud Armor 策略。
- **规则管理**：将 IP 分组成块（例如，每条规则 10 个）以符合 GCP 限制。
- **安全规则替换**：仅识别并替换此 Lambda 先前添加的规则，保留其他自定义规则。
- **安全凭证处理**：利用 AWS Secrets Manager 安全存储和访问 GCP 服务账号凭证。
- **事件驱动执行**：当 CloudFront IP 范围变化时由 AWS SNS 通知触发。[AWS 文档 - AWS IP 地址范围通知](https://docs.aws.amazon.com/vpc/latest/userguide/subscribe-notifications.html)

## 架构

_本节将包含一个图表来说明此解决方案的架构。_

![架构图](architecture-diagram.png)

## 工作原理

此解决方案旨在与现有的 Cloud Armor 规则共存。它专门管理与 AWS CloudFront IP 范围相关的规则，保持所有其他规则不变。

Lambda 函数通过在 `description` 字段中查找特定前缀（例如 `(Managed by AWS Lambda) CloudFront IPs chunk`）来识别它创建的规则。这使系统能够安全地仅删除这些条目并用最新版本替换它们。

此解决方案不依赖 DynamoDB 或 S3 进行状态跟踪。相反，Lambda 函数：

1. 从 AWS 的 [ip-ranges.json](https://ip-ranges.amazonaws.com/ip-ranges.json) 获取当前的 CloudFront IP 范围列表。
2. 将 IP 聚合并分组为每个 Cloud Armor 规则最多 10 个 CIDR 的块。
3. 使用 GCP API 检索现有的 Cloud Armor 策略。
4. 删除所有先前由 Lambda 创建的规则（通过特定描述前缀识别）。
5. 使用聚合的 CloudFront CIDR 创建一组新规则。
6. 使用 `patch` API 调用向 Google Cloud Armor 一次性提交所有更改，确保立即应用。

这种设计允许完全无状态操作，可以通过事件或手动触发，并且始终生成完整的最新策略，无需中间存储。

## 前提条件

### AWS

- **Secrets Manager**：在 AWS Secrets Manager 中存储您的 GCP 服务账号 JSON 凭证。
- **S3 存储桶**：用于存储打包的 Lambda Layer ZIP 文件的 S3 存储桶。
- **IAM 角色**：具有执行 Lambda 函数和访问 Secrets Manager 权限的 IAM 角色。

### GCP

- **服务账号**：创建具有以下角色的 GCP 服务账号：
  - **`roles/compute.securityAdmin`**：允许管理 Cloud Armor 安全策略。

- **Cloud Armor 安全策略**：确保您配置中指定的 Google Cloud Armor 安全策略已存在。

- **启用 API**：
  - 必须启用 **Compute Engine API**。您可以通过控制台或 CLI 启用它：
    - 控制台：[启用 Compute Engine API](https://console.developers.google.com/apis/api/compute.googleapis.com/overview)
    - CLI：
      ```bash
      gcloud config set project YOUR_PROJECT_ID
      gcloud services enable compute.googleapis.com
      ```

## 部署步骤

1. **克隆仓库**：
   ```bash
   git clone https://github.com/yourusername/gcp-cloudarmor-updater.git
   cd gcp-cloudarmor-updater
   ```

2. **打包 Lambda Layer**：
   使用提供的 shell 脚本将必要的 Python 依赖项打包成 Lambda Layer。
   ```bash
   sh ./scripts/package_layer.sh
   ```

3. **将 Layer 上传到 S3**：
   ```bash
   aws s3 cp layer.zip s3://your-s3-bucket-name/path/to/layer.zip
   ```

4. **部署 CloudFormation 堆栈**：
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

   使用 AWS CLI 在 AWS Secrets Manager 中存储您的 GCP 服务账号 JSON 凭证，名称为在 `GCPServiceAccountSecretName` 中指定的名称：

   ```bash
   aws secretsmanager create-secret \
     --name YourSecretName \
     --secret-string file://path/to/your-gcp-credentials.json
   ```

   将 `YourSecretName` 替换为您在部署参数中指定的名称，将 `path/to/your-gcp-credentials.json` 替换为您下载的 GCP JSON 凭证的路径。

6. **测试 Lambda 函数并在 Cloud Armor 中初始设置规则**：
   ```bash
   aws lambda invoke \
     --function-name GCPArmorUpdater \
     --payload '{}' \
     response.json
   ```

## 打包 Lambda Layer

`scripts/package_layer.sh` 脚本自动创建包含必要 Python 依赖项的 Lambda Layer。

在运行此脚本之前，请确保您的环境中已安装并可访问 `pip`。

## 贡献

我们欢迎社区贡献！请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解指南。

## 安全

有关更多信息，请参阅 [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications)。

## 许可证

此库根据 MIT-0 许可证授权。请参阅 [LICENSE](LICENSE) 文件。