# Darktide Schema 15 API 翻譯

轉接器從 ready 的 Schema 1／15 工作集處理 `AI_REQUIRED` 且 `pending` 的項目。它先驗證工作集綁定，再檢查可接續的狀態與可沿用的快取。通過結構檢查與獨立語意審查的項目才會回填。

## 執行

在 Skill repo 根目錄，以已備妥的 Python 3.11+ 環境執行。原始碼工作樹直接載入同 repo 的 `packages/claude-runner`。部署時使用相同版本的核心並保留 Skill repo 相對路徑佈局。

```text
python skills/auto-update-darktide-mod/api/darktide_translate.py run
  --workset <localization-workset.json> --mods-root <Mods repo>
  --state <api-state.json> --cache-dir <run cache>
  --summary-out <run>/api-summary.json [--mode update|improve]
  [--max-items N] [--dry-run]
```

上例各行是同一指令。預設 `update`，修訂時明確使用 `--mode improve`。正式呼叫的憑證由環境變數 `ANTHROPIC_API_KEY` 提供。預演會讀工作集、狀態和快取，建立分批及詞彙切片並輸出估算，寫入 JSON 與相鄰的同名 Markdown 摘要。費用估算依版本化價格表換算，以 Console 帳單為準。

| 結束碼 | 意義 |
| --- | --- |
| 0 | 處理完成或預演完成。個別 BLOCKED 項仍待人工處理。 |
| 2 | 待送數超過單次上限。經人工確認可指定 `--max-items`。 |
| 3 | API 呼叫停止。檢視摘要後以同一路徑接續。 |
| 4 | 工作集、綁定、狀態、設定或路徑不符。 |
| 5 | 正式呼叫缺少環境憑證。 |

狀態檔、快取與兩種摘要放於 run 目錄。每個工作集由同一個翻譯程序處理。狀態的 `worksetSha256` 採用工作集內的 `immutableContractSha256`，回填後可接續。API 中斷時已通過的項目會回填，當批的 `api_failed` 項可重試。其他 BLOCKED 項會保留原工作集狀態，並在摘要標示原因。

快取鍵依序包含 NEW 英文 raw、OLD 繁中 raw 或 JSON null、規則 SHA、詞彙表 SHA、模式及請求模型 ID。已審查通過且翻譯及審查回應模型均相符的結果才會寫入。若 PATH 有 `luac`，轉接器以暫存檔執行 `luac -p`；缺少時在摘要記錄 `luacAvailable: false`。

## 安全檢查

PowerShell 套用工作集與驗證收據時，會比對完整的 Lua token 序列。每個位置的類型都須一致，非字串 token 的文字也須一致。引號字串和長字串都視為字串，允許替換內容。因此，把 `Localize("key")` 改成 `Localize("other")` 仍會通過 PowerShell 結構檢查。Python 轉接器會在建立翻譯模板時以 `complex_expression` 擋下這類函式呼叫。

## 工作集綁定契約

```text
python skills/auto-update-darktide-mod/api/darktide_translate.py binding
  --mods-root <Mods repo> --mode <update|improve> --mod-relative-path <POSIX path>
  --base-oid <workset baseOid>
```

新版工作集的 PowerShell 產生器、收據驗證器及 Python `run` 都從 `baseOid` 的 Git blob 讀取 Mods 規則和詞彙表。比對新版工作集時，`binding` 使用同一個 `--base-oid`。省略這個參數時，`binding` 會讀取 Mods 工作樹。

工作集頂層 `translationBinding` 可由上述指令產生。PowerShell 與 Python 均讀 `config/rules-manifest.json`。採用下列位元組格式，以便跨語言交叉驗證。

1. 使用 `modes` 與 `modFilter` 篩選 `files`。空值適用所有 MOD，有值時以 `modRelativePath` 的最後一個 POSIX 路徑元件做不區分大小寫的完整比對。
2. `repo` 選定 Skill 或 Mods repo 根目錄。由根目錄以 POSIX 相對 `path` 取檔並讀取原始位元組，保留 BOM、CRLF 與 LF。對每檔取小寫十六進位 SHA-256。
3. 依 `(repo, path)` 逐欄以 ordinal 遞增排序，形成 `rulesManifest` 列表。
4. 將每列組成 `repo<TAB>path<TAB>sha256<LF>`，最後一列也有 LF。整段以無 BOM 的 UTF-8 編碼，再算小寫十六進位 SHA-256，即 `rulesSha256`。
5. `glossarySha256` 是 Mods repo `Referneces/Translation.md` 原始位元組的 SHA-256。使用同一份已雜湊的位元組解析本次詞彙表。
6. 輸出 `bindingVersion: 1`、`mode`、設定檔的 `modelId`、`rulesSha256`、`glossarySha256` 及 `rulesManifest`。工作集產生器將整個物件納入不可變契約。若綁定缺少或與重算結果不符，執行以 4 結束。

回填只替換已通過項目的 `reviewStatus` 與 `suggestedZhTwExpression` 值，保留原 JSON 的其餘位元組及 `immutableContractSha256`。PowerShell 契約對固定的工作集與單元欄位投影雜湊，兩個回填欄位在投影之外。JSON 及 Markdown 摘要應在工作集刪除前保留於 run 目錄，供 PR 內文取得。

## 離線測試

```text
python -m pytest packages/claude-runner/tests skills/auto-update-darktide-mod/api/tests -q
```

設定 `DARKTIDE_MODS_ROOT` 可額外驗證真實詞彙表。整合測試使用合成工作集與假 transport。
