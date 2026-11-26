"""同步輸出 JSON 收據與可貼入 PR 的繁體中文摘要。"""

import re
from collections import Counter

from claude_runner.state import atomic_json, atomic_text


API_MESSAGES = {
    "authentication": "認證失敗",
    "spend_limit": "帳戶花費上限已到",
    "timeout": "API 呼叫逾時",
    "connection": "API 連線失敗",
    "overloaded": "API 過載，已達重試上限",
    "rate_limit": "API 限流，已達重試上限",
    "server_error": "API 伺服器錯誤，已達重試上限",
    "max_tokens": "API 輸出截斷，已達重試上限",
    "unit_id_mismatch": "API 回應項目與請求不符，已達重試上限",
    "invalid_output": "API 回應格式無效，已達重試上限",
    "empty_response": "API 回應為空，已達重試上限",
    "refusal": "API 拒絕回應，已達重試上限",
}

BLOCK_LABELS = {
    "needs_lookup_definition": "需要 lookup 定義",
    "max_corrections_reached": "已達修正上限",
    "complex_expression": "無法安全建立 Lua 模板",
    "api_failed": "API 失敗，可接續",
}
WARNING_LABELS = {"unexpected_outer_double_quotes": "已移除多餘的外層雙引號"}
STATUS_LABELS = {
    "completed": "處理完成", "dry-run": "預演", "needs-confirmation": "需要人工確認",
    "missing-key": "缺少憑證", "api-failed": "API 中斷",
}


def api_message(code):
    return API_MESSAGES.get(code, "API 請求失敗")


def markdown_text(text):
    # 避免外部資料的本機路徑、換行及 Markdown 控制字元進入 PR。
    text = re.sub(r'(?i)(?:[a-z]:[\\/]|\\\\|(?<![\w/])/(?!/))[^ \t\r\n]*', "（路徑已省略）", text)
    return re.sub(r"([\\<>&*_\[\]\x60|])", r"\\\1", " ".join(text.split()))


def write_summary(path, report, records, usage, prices):
    blocked = []
    unknown_terms = []
    warnings = []
    for unit_id, record in records.items():
        if reason := record.get("blockedReason"):
            item = {"unitId": unit_id, "reason": reason}
            if record.get("details"):
                item["details"] = record["details"]
            blocked.append(item)
        if terms := record.get("unknownTerms"):
            unknown_terms.append({"unitId": unit_id, "key": record["key"], "source": record["source"],
                                  "terms": terms, "translation": record["expression"]})
        warnings.extend({"unitId": unit_id, "code": code} for code in record.get("warnings", []))

    report.update(
        processedCount=sum(record.get("status") in ("approved", "blocked") for record in records.values()),
        approvedCount=sum(record.get("status") == "approved" for record in records.values()),
        cacheHitCount=sum(record.get("origin") == "cache" for record in records.values()),
        blocked=blocked,
        unknownTerms=unknown_terms,
        warnings=warnings,
        corrections=dict(sorted(Counter(record.get("corrections", 0) for record in records.values()
                                        if record.get("status") in ("approved", "blocked")).items())),
        usage=usage.data,
        estimatedUsageUsd=usage.cost(prices),
    )
    atomic_json(path, report)
    lines = [
        "## Claude API 臺灣繁中翻譯",
        "",
        f"- 狀態：{STATUS_LABELS[report['status']]}",
        f"- 模式：{report['mode']}，模型：{report['model']}",
        f"- 規則 SHA-256：{report['rulesSha256']}",
        f"- 詞彙表 SHA-256：{report['glossarySha256']}",
        f"- 待送 API {report['apiItemCount']} 項，共 {report['batchCount']} 批，單次上限 {report['maxItems']} 項。",
        (f"- 已處理 {report['processedCount']} 項，通過 {report['approvedCount']} 項，"
         f"沿用 {report['cacheHitCount']} 項，BLOCKED {len(blocked)} 項，非 AI {report['nonAiCount']} 項。"),
        f"- Lua 語法檢查器可用：{'是' if report['luacAvailable'] else '否'}。",
    ]
    if report["maxItemsOverride"] is not None:
        lines.append(f"- 上限經人工覆寫為 {report['maxItemsOverride']}。")
    if report.get("message"):
        lines.append(f"- {report['message']}")
    estimate = report["estimate"]
    lines += [
        (f"- 本次待送估計輸入 {estimate['input_tokens']:,} tokens、輸出 {estimate['output_tokens']:,} tokens，"
         f"估計費用 USD {estimate['estimatedUsd']:.6f}。"),
        f"- 累計用量估計費用 USD {report['estimatedUsageUsd']:.6f}，以 Console 帳單為準。",
        "",
        "| 角色 | 請求 | 重試 | 輸入 tokens | 輸出 tokens | 快取寫入 tokens | 快取讀取 tokens |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for role, label in (("translator", "翻譯"), ("reviewer", "審查")):
        row = report["usage"][role]
        cells = " | ".join(str(row[key]) for key in ("requests", "retries", "input_tokens",
                           "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        lines.append(f"| {label} | {cells} |")
    if report["corrections"]:
        distribution = "、".join(f"{count} 次修正 {units} 項" for count, units in report["corrections"].items())
        lines += ["", f"修正分佈：{distribution}。"]
    if blocked:
        lines += ["", "### BLOCKED 項目", ""]
        lines.extend(f"- {markdown_text(item['unitId'])} — {BLOCK_LABELS[item['reason']]}（{item['reason']}）"
                     for item in blocked)
    if unknown_terms:
        lines += ["", "### 待確認術語", ""]
        for item in unknown_terms:
            terms = "、".join(markdown_text(term) for term in item["terms"])
            lines.append(f"- {markdown_text(item['key'])} — {terms}")
    if warnings:
        lines += ["", "### 警告", ""]
        lines.extend(f"- {markdown_text(item['unitId'])} — {WARNING_LABELS[item['code']]}（{item['code']}）"
                     for item in warnings)
    lines += ["", "<details>", "<summary>規則檔清單</summary>", ""]
    lines.extend(f"- {row['repo']}/{row['path']}　{row['sha256']}" for row in report["rulesManifest"])
    lines += ["", "</details>", ""]
    atomic_text(path.with_suffix(".md"), "\n".join(lines))
