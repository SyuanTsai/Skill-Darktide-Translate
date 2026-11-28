# Darktide Schema 15 API 翻譯

Skill 提供 Schema 15 API 翻譯資產，以及產生、套用工作集和驗證收據的 PowerShell 腳本。PowerShell 從 Skill 資產與工作集基準版本的 Mods 規則和詞彙表計算並驗證 `translationBinding`。

## Skill 檔案

下列路徑皆相對於 Skill 根目錄。

- `assets/api-translator-prompt.md`
- `assets/api-reviewer-prompt.md`
- `assets/api-translator-output.schema.json`
- `assets/api-reviewer-output.schema.json`
- `assets/api-translation.json`
- `assets/api-rules-manifest.json`

## 執行

Python 轉接器的 repo 路徑是 `packages/darktide-translate/darktide_translate.py`。它不隨 Skill 安裝，只能從 repo 原始碼工作樹或 GitHub Actions 執行。在 repo 根目錄以已備妥的 Python 3.11+ 環境執行，轉接器會載入同 repo 的 `packages/claude-runner`。

Codex 或 Claude 都可從同一個原始碼工作樹呼叫下列 CLI。請使用與轉接器同版本的 PowerShell 套件產生工作集，並在執行後接續 `localization`，由現有流程套用工作集與驗證收據。

轉接器處理 ready 的 Schema 15 工作集中同時為 `AI_REQUIRED` 與 `pending` 的項目。它會先驗證工作集綁定，再讀取狀態及快取。通過結構檢查與獨立語意審查的項目才會回填。

```text
python packages/darktide-translate/darktide_translate.py run
  --workset <localization-workset.json> --mods-root <Mods repo>
  --state <api-state.json> --cache-dir <run cache>
  --summary-out <run>/api-summary.json [--mode update|improve]
  [--gameplay-context <context.json>] [--max-items N] [--dry-run]
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

有待確認術語的譯文照常進行結構檢查與獨立審查。JSON 摘要的頂層 `unknownTerms` 是已採用譯文的彙整陣列，無項目時為 `[]`。每筆包含字串欄位 `unitId`、`key`、`source`、`translation`，以及字串陣列 `terms`。`source` 是工作集的 NEW 英文 Lua 表達式，`translation` 是回填的臺灣繁中 Lua 表達式。Markdown 摘要在「待確認術語」列出 key 與詞清單。

`needsLookupDefinition` 標記的譯文通過結構檢查及審查後照常採用。若查詞時無可用譯文，先採結構相容的 NEW 繁中，再查 OLD 繁中，最後以原始英文運算式回填。無法安全模板化且已驗證語法的運算式會記為 `reviewStatus: preserved`，並維持 `suggestedZhTwExpression: null`。Apply 和 Receipt 保留該筆 NEW 欄位的原始位元組。

JSON 摘要的 `termReviews` 沿用術語欄位，另含 `reason` 及 `adoption`。原因可為 `needs_lookup_definition`、`max_corrections_reached` 或 `complex_expression`，`translation` 記載實際採用或保留的 Lua 值。Markdown 摘要在「待確認術語」列出原因、待確認詞及採用值。

修正次數用盡且最後只剩文字品質問題（如語意、數值或術語）時，沿用相同的回退順序。回退項不進入翻譯快取，並以 `max_corrections_reached` 和 `lastFailure` 記錄最後的檢查代碼或審查意見。已保存且綁定相同工作集的文字問題可直接回退。Lua、格式參數、遊戲字串引用、佔位符、色碼與換行等結構檢查仍然適用。

若英文原文沒有外層雙引號，轉接器會在審查前移除整段譯文多餘的外層雙引號。採用這筆譯文時，JSON 摘要的 `warnings` 陣列會記錄 `unitId` 和 `code: "unexpected_outer_double_quotes"`。

快取鍵包含 NEW 英文、OLD 英文、OLD 繁中、NEW 繁中候選的 raw 值（缺少時為 JSON null），以及規則 SHA、詞彙表 SHA、模式與請求模型 ID。舊格式的快取會自然失效。已審查通過且翻譯及審查回應模型均相符的結果才會寫入。轉接器使用 PATH 中的 `luac -p` 或 LuaJIT 編譯檢查運算式。兩者皆缺少時，摘要記錄 `luacAvailable: false`，運算式由內建解析器驗證。

## 提供遊戲脈絡

Mods 端在有待審單元需要程式碼才能確認語意時，產生獨立的 JSON 並傳給 `run --gameplay-context`。從工作集複製該筆的完整 `unitId` 和 `key`。選用已核實代表該次候選內容的 Mods commit 或 tree，並確保 Git 物件已在 `--mods-root` 本機可讀。標準壓縮檔更新流程可能沒有對應的上游 Git 物件，Mods 端可用候選檔案的原始位元組建立本機 Git tree，並在 tree 內使用完整的 Mods 儲存庫相對路徑。若直接使用既有 commit，先核對其 localization 和相關 runtime 與候選內容相同。工作集仍使用原有的產生、回填和套用格式。

```json
{
  "version": 1,
  "candidateOid": "<40-character Mods commit or tree OID>",
  "localizationPath": "Warhammer 40,000 DARKTIDE/mods/ChatBlock/scripts/mods/ChatBlock/ChatBlock_localization.lua",
  "units": {
    "<exact workset unitId>": {
      "key": "auto_melee_swap_wait_for_reload_tooltip",
      "references": [
        {"path": "Warhammer 40,000 DARKTIDE/mods/ChatBlock/scripts/mods/ChatBlock/ChatBlock.lua", "startLine": 20, "endLine": 127}
      ]
    }
  }
}
```

行號從 1 開始，包含起迄行。以核實的 Git 物件為準填寫上述路徑。轉接器比對 localization blob 的 SHA-256 與工作集 `new.sha256`，再依單元的 byte span 核對 NEW 英文原始運算式。每筆最多 4 段，合計最多 120 行、8 KiB。只接受工作集所選 MOD 子樹內的普通 Lua 檔。MOD 根目錄格式為 `Warhammer 40,000 DARKTIDE/mods/<name>` 或舊版的 `mods/<name>`。摘錄須取自 runtime 檔、互不重疊，且保留檔案中未擷取的行。轉接器從本機 Git 讀取每個最多 1 MiB 的 blob。JSON 檔上限為 256 KiB，內容只需版本、候選 OID、localization 路徑、單元識別及行號範圍。

ChatBlock #379 的來源是 Mods main `d4377f7af97c3aacd7eac66c5d2feddda765943f`，配合該版本的 tooltip 和 `ChatBlock.lua` 第 20–127 行。審查時應核對 `focus_lost()`、`ranged_reload_active()`、`auto_melee_swap_on_blocked(blocked)` 和 `HumanGameplay._input_active` hook。若裝填完成前關閉聊天、選單或 Steam 內嵌介面，或切回遊戲視窗，恢復角色操控會清除擱置的切換並保留遠程武器。若裝填完成時操控仍受阻，才會切換至近戰武器。接入 Mods 流程時，請從當次候選版本重新核對路徑與行號。

ChatBlock 的該筆 tooltip，以及脈絡檔列出的單元，都需要有效證據。缺少證據、候選來源或範圍驗證失敗、或 reviewer 判定證據不足時，該筆維持 pending。摘要分別顯示 `gameplay_context_missing`、`gameplay_context_invalid` 或 `gameplay_context_insufficient`。Reviewer 也能對其他確實依賴遊戲行為的單元回報證據不足。脈絡檔的整體格式錯誤或含未知單元時，命令結束碼為 4。

需要遊戲脈絡的單元必須通過審查才會回填。查詞無可用譯文或修正次數用盡時，即使沿用同一狀態檔重跑，也不採用文字回退。

摘錄只送入對應單元的 reviewer 請求。狀態及快取以驗證後的脈絡雜湊綁定審查結果。更正證據後，以新的 `--state` 路徑重跑。若要重新審查已回填的項目，使用含該筆 pending 單元的原始工作集。既有的規則綁定仍適用。若未完成的工作集綁定了舊版 reviewer 資產，以現行規則另行產生工作集並保留歷史檔案。

## 安全檢查

PowerShell 在套用工作集與驗證收據時比對完整的 Lua token 序列、格式規格的內容與順序，以及遊戲字串引用。資料欄位越界、結構變動、引用變動與收據不一致都會停止套用或驗證。Mods 編排器在發布前另對候選檔執行 LuaJIT 語法檢查。

## 工作集綁定契約

```text
python packages/darktide-translate/darktide_translate.py binding
  --mods-root <Mods repo> --mode <update|improve> --mod-relative-path <POSIX path>
  --base-oid <workset baseOid>
```

新版工作集的 PowerShell 產生器、收據驗證器及 Python `run` 都從 `baseOid` 的 Git blob 讀取 Mods 規則和詞彙表。比對新版工作集時，`binding` 使用同一個 `--base-oid`。省略這個參數時，`binding` 會讀取 Mods 工作樹。

PowerShell 工作集產生器和收據驗證器從 Skill 資產讀取規則清單及模型設定。Python 使用相同資產，上述指令可輸出 `translationBinding` 供交叉驗證。兩端採用相同的位元組格式。

1. 使用 `modes` 與 `modFilter` 篩選 `files`。空值適用所有 MOD，有值時以 `modRelativePath` 的最後一個 POSIX 路徑元件做不區分大小寫的完整比對。
2. `repo` 選定 Skill 或 Mods repo 根目錄。由根目錄以 POSIX 相對 `path` 取檔並讀取原始位元組，保留 BOM、CRLF 與 LF。對每檔取小寫十六進位 SHA-256。
3. 依 `(repo, path)` 逐欄以 ordinal 遞增排序，形成 `rulesManifest` 列表。
4. 將每列組成 `repo<TAB>path<TAB>sha256<LF>`，最後一列也有 LF。整段以無 BOM 的 UTF-8 編碼，再算小寫十六進位 SHA-256，即 `rulesSha256`。
5. `glossarySha256` 是 Mods repo `Referneces/Translation.md` 原始位元組的 SHA-256。使用同一份已雜湊的位元組解析本次詞彙表。
6. 輸出 `bindingVersion: 1`、`mode`、設定檔的 `modelId`、`rulesSha256`、`glossarySha256` 及 `rulesManifest`。工作集產生器將整個物件納入不可變契約。若綁定缺少或與重算結果不符，執行以 4 結束。

回填只替換處置完成項目的 `reviewStatus` 與 `suggestedZhTwExpression` 值，保留原 JSON 的其餘位元組及 `immutableContractSha256`。PowerShell 契約對固定的工作集與單元欄位投影雜湊，兩個回填欄位在投影之外。JSON 及 Markdown 摘要應在工作集刪除前保留於 run 目錄，供 PR 內文取得。

## 離線測試

```text
python -m pytest packages/claude-runner/tests tests/python/darktide_api -q
```

設定 `DARKTIDE_MODS_ROOT` 可額外驗證真實詞彙表。整合測試使用合成工作集與假 transport。
