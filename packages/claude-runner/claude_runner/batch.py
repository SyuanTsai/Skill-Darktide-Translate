"""由呼叫端注入解析、檢查、審查決策與完成動作的流程。"""

from dataclasses import dataclass, field
from typing import Callable

from .client import ApiError


def batches(items, size):
    for start in range(0, len(items), size):
        yield items[start:start + size]


@dataclass
class Progress:
    attempts: int = 0
    corrections: int = 0
    feedback: list = field(default_factory=list)
    cacheable: bool = True


@dataclass
class BatchCallbacks:
    translate: Callable
    inspect: Callable
    review: Callable
    finish: Callable


def process_batch(items, progress, model, max_corrections, callbacks):
    """傳回 API 錯誤或 None。所有已終止項目會立即交給 finish。"""
    pending = list(items)
    while pending:
        try:
            translated = callbacks.translate(pending, progress)
        except ApiError as error:
            for unit_id in pending:
                callbacks.finish(unit_id, progress[unit_id], "api_failed")
            return error

        retry = []
        reviewable = {}

        def correct(unit_id, feedback):
            step = progress[unit_id]
            step.feedback = feedback
            if step.corrections >= max_corrections:
                callbacks.finish(unit_id, step, "max_corrections_reached")
            else:
                step.corrections += 1
                retry.append(unit_id)

        for unit_id in pending:
            step = progress[unit_id]
            step.attempts += 1
            step.cacheable &= translated.model == model
            reason, issues, value = callbacks.inspect(unit_id, translated.items[unit_id])
            if reason:
                callbacks.finish(unit_id, step, reason, details=value)
            elif issues:
                correct(unit_id, issues)
            else:
                reviewable[unit_id] = value

        if reviewable:
            try:
                reviewed = callbacks.review(reviewable)
            except ApiError as error:
                for unit_id in (*reviewable, *retry):
                    callbacks.finish(unit_id, progress[unit_id], "api_failed")
                return error

            for unit_id, value in reviewable.items():
                step = progress[unit_id]
                step.cacheable &= reviewed.model == model
                verdict = reviewed.items[unit_id]
                if verdict["verdict"] == "pass":
                    callbacks.finish(unit_id, step, None, value=value, review=verdict)
                else:
                    correct(unit_id, verdict["issues"])
        pending = retry
    return None
