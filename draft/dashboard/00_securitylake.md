Short answer: **No — the Splunk App for AWS Security Dashboards will not populate if your only data feed is Security Lake (`aws:asl`).** Here's why, based on how the app is wired:

**The app's panels are hardcoded to native sourcetypes, not `aws:asl`.** Each dashboard panel is keyed to a specific source type — Splunk's own troubleshooting guidance is that if a panel shows zeroes, you search that panel's sourcetype (e.g., `sourcetype=aws:config:notification` for the Changes Over Time panel on Resource Activity) to verify data is arriving. The app's searches look for `aws:cloudtrail`, `aws:config:notification`, `aws:cloudwatchlogs:vpcflow`, and similar native sourcetypes. Your Security Lake input tags everything as `aws:asl`, so every panel query returns zero events.

**The field names don't match either, so re-tagging won't fix it.** This is the deeper problem. Even if you overrode the sourcetype on your CloudTrail-origin Security Lake events to `aws:cloudtrail`, the panels would still break, because Security Lake data is OCSF-normalized Parquet — the fields are `api.operation`, `actor.user`, `src_endpoint.ip`, etc., not the native CloudTrail JSON fields (`eventName`, `userIdentity`, `sourceIPAddress`) that the add-on's props/transforms extract and the app's searches and three included data models depend on. The schema transformation Security Lake performed on the way in is exactly what disconnects the data from the app's knowledge objects. And as we covered, the add-on ships zero CIM/data model mappings for `aws:asl`.

**Also worth knowing:** the app relies on the Splunk Add-on for AWS version 6.0.0 or later, so your add-on setup is fine — the gap is purely on the data side, not the dependency side.

Your realistic options, in order of practicality:

1. **Run parallel native inputs for the sourcetypes the app needs.** Keep Security Lake as your aggregation/lake layer, but also ingest CloudTrail (SQS-Based S3 from the org trail bucket) and Config notifications natively so the app has `aws:cloudtrail` and `aws:config:notification` to work with. Downside: dual ingestion cost for overlapping data.

2. **Skip the app and build OCSF-native dashboards.** Since you already have the OCSF-to-CIM query pack, extending that into a dashboard layer over `aws:asl` gives you equivalent visibility without double-ingesting. For a Security Lake-only architecture this is the cleaner long-term path.

3. **Search-time translation into the app** (props/transforms or field aliases mapping OCSF fields onto CIM/native names plus eventtype/tag surgery) is technically possible but fragile — you'd be reverse-engineering every panel search, and app updates would break it. I wouldn't recommend it.

If the goal of the app was mainly the Security Overview visuals (CloudTrail activity, error/auth failures, config changes), option 2 is honestly not much work — most of those panels are `tstats`/`stats` over fields you've already mapped in your query pack. Want me to draft an OCSF-native equivalent of the Security Overview dashboard as Simple XML or a dashboard studio definition against `aws:asl`?
