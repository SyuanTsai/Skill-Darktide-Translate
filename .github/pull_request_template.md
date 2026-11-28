<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
## 驗證環境

請貼上 `tests/Invoke-Tests.ps1` 結果中的 `environment` JSON。證據至少必須包含：

- PowerShell (`pwsh`) 版本與執行檔路徑
- Pester 版本、manifest 路徑與 SHA-256
- 作業系統與架構
- 執行身分（user）
- Git HEAD commit

```json
{}
```

CI 的版本以 consumer gate leg receipt 為準。
