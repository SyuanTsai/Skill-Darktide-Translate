# claude-runner 0.1.0

此套件提供 Python 3.11+ 的 Claude 結構化輸出、分批審查、逐項接續、結果快取與用量估算。執行期套件及傳遞相依版本記錄在 `requirements.lock`。

## 接入流程

1. 由呼叫端確認輸入版本、建立待處理項目與穩定的 ID，備妥翻譯和審查各自的 system 內容及 JSON Schema。
2. 實作 `client.Transport.send(Request) -> Response`。正式執行可在入口讀取環境變數 `ANTHROPIC_API_KEY` 後傳入 `transport_anthropic.AnthropicTransport`，並在結束時呼叫 `close()`。本機測試可用 `client.FakeTransport`，依序回傳物件、核心例外或依請求產生回應的函式。
3. 建立 `budget.Usage` 和 `client.Client`，指定模型、兩個角色的 effort、輸出 token 上限與重試秒數。用 `Client.call()` 傳入角色、system、user 資料、schema 及本批 ID。成功回傳按 ID 索引的 `Result.items` 與回應模型 ID。可注入 `sleeper` 和落盤用量的回呼。
4. 使用 `batch.batches()` 排程。將翻譯、結構檢查、審查、結案四個回呼交給 `batch.process_batch()`。結構檢查回傳阻擋原因、可修正問題及審查資料。結案回呼收到逐項進度與通過或阻擋結果，可使用 `state.State.set_unit()` 即時原子寫入。
5. 由呼叫端決定工作身分與快取身分。狀態身分在續跑時必須相符。`cache.Cache` 以排序鍵、緊密分隔符及 UTF-8 的 canonical JSON 算 SHA-256，檔案分存於鍵前兩碼的子目錄。呼叫端應在寫入前確認結構、審查及回應模型皆符合要求。

`RetryableApiError` 表示可依退避設定重試，`FatalApiError` 立即終止當次呼叫。SDK 自動重試設為零。核心會在每次嘗試後累計請求、重試與回應用量，包括後續因截斷或格式無效而重試的回應。對外摘要請使用受控的錯誤代碼對照，避免序列化原始 SDK 例外、HTTP headers 或憑證。

## 合成 API smoke

在已安裝 `requirements.lock` 的 Python 環境，從固定 Skill commit 的 `packages/claude-runner` 執行下列指令。只有明確傳入 `--live` 才讀取環境變數 `ANTHROPIC_API_KEY` 並呼叫 Anthropic。

```text
python -B -m claude_runner.smoke --live
```

讀取憑證前，指令會驗證 SDK 環境。允許 `ANTHROPIC_BASE_URL` 未設定，或設為 `https://api.anthropic.com`（可帶結尾斜線）。若 `ANTHROPIC_LOG` 設為 SDK 會啟用日誌的 `debug` 或 `info`，或 `ANTHROPIC_CUSTOM_HEADERS` 含值，指令會以固定代碼結束。

指令以 `claude-sonnet-5-5` 翻譯並審查一筆內建合成資料。每次執行最多兩次 Messages API 請求，每次上限 512 個輸出 token、逾時 30 秒，SDK 和 runner 均停用重試。兩次回應都要通過結構、合成單元 ID、回應模型與內容比對才會成功。指令只讀取程式內的合成輸入，對標準輸出寫一列 JSON，成功時包含模型、請求數及輸入與輸出 token 計數，失敗時包含固定錯誤代碼。此檢查涵蓋 runner 的 SDK transport 與結構化翻譯和審查，適用範圍到 runner 回應驗證為止。

若從保存 Anthropic 憑證的 Mods Actions 執行，使用獨立的 `.github/workflows/claude-runner-smoke.yml`。觸發只用 `workflow_dispatch`，GitHub 權限至多為 `contents: read`。只 checkout `SyuanTsai/Skill-Darktide-Translate`，將審查通過且含 smoke 的完整 commit SHA 寫入 workflow 並比對 checkout 的 HEAD，設 `persist-credentials: false`。先依鎖檔安裝相依套件，再於執行 smoke 的單一步驟注入 `ANTHROPIC_API_KEY`。run log 保留固定 SHA 與 JSON 診斷，GitHub 只負責唯讀 checkout，工作不需要 Mods 工作樹、GitHub 寫入憑證或發布步驟。

從 Skill checkout 根目錄執行下列指令可離線測試，包括固定請求內容、模型與回應邊界。測試使用假的憑證，並以本機 HTTP mock 攔截 SDK 呼叫。

```text
python -B -m pytest -p no:cacheprovider packages/claude-runner/tests/test_smoke.py -q
```
