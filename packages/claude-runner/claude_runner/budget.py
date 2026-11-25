"""呼叫上限、用量與費用換算。"""

ROLES = ("translator", "reviewer")
PRICE_FIELDS = {
    "input_tokens": "input",
    "output_tokens": "output",
    "cache_creation_input_tokens": "cacheWrite",
    "cache_read_input_tokens": "cacheRead",
}


def exceeds_budget(api_items, limit):
    return api_items > limit


def estimated_cost(tokens, prices):
    return sum(tokens.get(field, 0) * prices[rate] for field, rate in PRICE_FIELDS.items()) / 1_000_000


class Usage:
    def __init__(self, data=None):
        self.data = {
            role: {key: (data or {}).get(role, {}).get(key, 0)
                   for key in ("requests", "retries", *PRICE_FIELDS)}
            for role in ROLES
        }

    def record(self, role, *, retry=False, tokens=None):
        counters = self.data[role]
        counters["requests"] += 1
        counters["retries"] += int(retry)
        for field in PRICE_FIELDS:
            counters[field] += (tokens or {}).get(field) or 0

    def cost(self, prices):
        return sum(estimated_cost(counters, prices) for counters in self.data.values())
