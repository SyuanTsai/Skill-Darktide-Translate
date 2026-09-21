---
name: investigate-datadog-logs
description: Investigate error logs and APM telemetry through a configured Datadog purpose-built connector. Use for Logs Explorer URLs, trace or investigation widget URLs, raw or aggregated log questions, span or trace analysis, and incidents that require Datadog telemetry. Do not use solely to manage incident records, dashboards, or notebooks.
---

# Investigate Datadog Logs

## Prepare

1. Use the configured Datadog connector before any general-purpose Browser tool.
2. If the exact guide name is not already known from the current turn, list Datadog guides before loading one; do not guess its name.
3. Load only the applicable connector guides:
   - Logs, patterns, or field discovery: `datadog/logs`.
   - Log counts, trends, or group-by analysis: `datadog/logs` and `datadog/ddsql` before calling the analysis tool.
   - Raw spans or trace details: `datadog/traces`.
   - Widget rendering or visualization: `datadog/visualizations`.
   - An incident record used to establish telemetry scope: the connector's incident guide.
4. If a guide recommends a capability that is not exposed, continue with the closest connector-supported path. Missing semantic log search alone is not a reason to use a Browser: build a concrete query only from supplied evidence, or request the minimum missing scope.

## Establish Scope

Preserve query text, filters, service, environment, identifiers, indexes, storage tier, grouping, timezone, and time supplied by the user, URL, or incident. Do not invent service or environment values; an intentionally broad query may leave either dimension unfiltered.

Apply time ranges in this order:

1. Use an explicit user, URL, or incident time range unchanged.
2. Otherwise start at `now-4h` and end at `now`. This default covers the typical three-to-four-hour delay between a problem and its report; disclose that it was applied.
3. Shorten that range only when the query times out or its volume is too large, and report the narrower range and reason.

Ask only when an ambiguous absolute time or timezone would materially change the result.

## Interpret Datadog URLs

- For a transparent Logs Explorer URL, extract supported query, time, index, storage, and timezone state and pass those values to the connector. Ignore presentation-only state.
- For a trace URL, extract and validate the trace ID, then retrieve the trace. Use explicit URL time or observed trace timestamps for related log searches.
- For a supported widget, share, or focused-dashboard URL used in the investigation, load the visualization guide and pass the exact `widget_url` to the widget tool.
- For an opaque non-widget short link or session-only UI state, try no invented translation. Fall back to a Browser only if the connector cannot resolve the required state.

A Datadog URL does not by itself require web UI operation and does not switch the connector to another organization. Do not substitute a different site or dataset when a mismatch is known.

## Choose the Data Path

- Use raw log search for individual events, exact messages, stack traces, request or correlation IDs, and small samples.
- Use log patterns when many similar entries need clustering; group only by supplied or discovered fields.
- Use raw log search with `extra_fields` to discover attributes or tags before referencing unknown fields in analysis. Translate discovered field names according to the logs guide.
- Use log analysis with DDSQL for counts, trends, distributions, group-by analysis, and top values. Follow the analysis tool's schema when generic DDSQL examples differ.
- Use raw span search for individual failing or slow spans and attribute discovery.
- Use span aggregation for APM counts, percentiles, trends, and grouping.
- Use trace retrieval when a valid trace ID is known. Start with a summarized service-entry view for a large trace, then expand only the spans needed for evidence.

When correlating logs and traces, retain the same semantic time and identifiers but translate filters using each data source's guide; do not mechanically reuse unsupported field syntax. Run independent connector queries in parallel after the scope is established when that reduces incident latency.

## Fallback and Report

Use a Browser only when the connector is unavailable, unauthorized, cannot perform the required operation, cannot resolve necessary opaque URL state, or the user explicitly requests UI interaction. State the connector limitation before falling back and preserve the original scope in an existing authorized session.

If neither path can access the requested scope, report the missing access or capability instead of inventing results.

Summarize the effective time range and its source, filters, connector path, observed evidence, inferences, remaining uncertainty, and any timeout-driven narrowing. Redact credentials, sensitive URL parameters, and unrelated telemetry.
