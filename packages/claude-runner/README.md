# claude-runner 0.1.0

此套件提供 Python 3.11+ 的 Claude 結構化輸出、分批審查、逐項接續、結果快取與用量估算。執行期套件及傳遞相依版本記錄在 `requirements.lock`。

## 接入流程

1. 由呼叫端確認輸入版本、建立待處理項目與穩定的 ID，備妥翻譯和審查各自的 system 內容及 JSON Schema。
2. 實作 `client.Transport.send(Request) -> Response`。正式執行可在入口讀取環境變數 `ANTHROPIC_API_KEY` 後傳入 `transport_anthropic.AnthropicTransport`，並在結束時呼叫 `close()`。本機測試可用 `client.FakeTransport`，依序回傳物件、核心例外或依請求產生回應的函式。
3. 建立 `budget.Usage` 和 `client.Client`，指定模型、兩個角色的 effort、輸出 token 上限與重試秒數。用 `Client.call()` 傳入角色、system、user 資料、schema 及本批 ID。成功回傳按 ID 索引的 `Result.items` 與回應模型 ID。可注入 `sleeper` 和落盤用量的回呼。
4. 使用 `batch.batches()` 排程。將翻譯、結構檢查、審查、結案四個回呼交給 `batch.process_batch()`。結構檢查回傳阻擋原因、可修正問題及審查資料。結案回呼收到逐項進度與通過或阻擋結果，可使用 `state.State.set_unit()` 即時原子寫入。
5. 由呼叫端決定工作身分與快取身分。狀態身分在續跑時必須相符。`cache.Cache` 以排序鍵、緊密分隔符及 UTF-8 的 canonical JSON 算 SHA-256，檔案分存於鍵前兩碼的子目錄。呼叫端應在寫入前確認結構、審查及回應模型皆符合要求。

`RetryableApiError` 表示可依退避設定重試，`FatalApiError` 立即終止當次呼叫。SDK 自動重試設為零。核心會在每次嘗試後累計請求、重試與回應用量，包括後續因截斷或格式無效而重試的回應。對外摘要請使用受控的錯誤代碼對照，避免序列化原始 SDK 例外、HTTP headers 或憑證。
