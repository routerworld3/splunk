Short answer up front: the data is completely fine, and yes, Splunk can absolutely query it. "Not CIM-normalized" doesn't mean broken or half-ingested — it means the data stops one rung short of the machinery that Enterprise Security's prebuilt content runs on. Let me show the ladder, because the whole thing makes sense once you see where the data lands on its own versus where it needs a push.The two green rungs are what you get for free the moment the SQS-Based S3 input with the Security Lake decoder is running. The gap is at the amber rung.

## Is the data any good? Yes — and it's arguably in better shape than most raw logs

When the add-on ingests Security Lake objects as `aws:asl`, it decodes the OCSF Parquet into events and Splunk auto-extracts the OCSF JSON structure. So you don't just get a blob of text — you get every OCSF field as a real, typed, searchable field: `class_uid`, `activity_id`, `severity_id`, `time`, `metadata.product.name`, `actor.user.name`, `src_endpoint.ip`, `dst_endpoint.ip`, and so on. That's rung two on the ladder. The data is fully indexed, fully parsed, and fully field-addressable.

In fact OCSF is itself a normalization schema — AWS already did the work of taking messy CloudTrail/VPC/Route53/etc. logs and forcing them into one consistent structure. So this isn't raw sludge; it's already-normalized data. It's just normalized to the *wrong* standard for Splunk ES, which speaks CIM. More on that in a second.

## Can Splunk query it? Completely — this is the key misconception to drop

Raw SPL works against `aws:asl` with zero extra setup. You can search, filter on any OCSF field, stats, build dashboards, write your own alerts and even your own correlation searches. For example:

```spl
index=aws_security_lake sourcetype=aws:asl class_uid=3002
| stats count by activity_name, actor.user.name, src_endpoint.ip
```

That runs today, no mapping required. "Not CIM-normalized" never means "unsearchable." It means the *prebuilt* content doesn't auto-recognize it. Anything you write by hand against the OCSF fields is unaffected.

## So what does "invisible to ES data models" actually mean?

Enterprise Security is built almost entirely on top of accelerated CIM data models, queried with `tstats`. A CIM data model is basically a saved constraint plus a required set of field names. The Authentication data model, for instance, only collects events that are tagged `authentication` and expects fields literally named `user`, `src`, `dest`, `action` (with values like `success`/`failure`), and `app`.

Your `aws:asl` data has the *equivalent information*, but under OCSF names and OCSF encodings:

- OCSF `actor.user.name` holds the user — but CIM wants a field called `user`.
- OCSF `src_endpoint.ip` holds the source — CIM wants `src`.
- OCSF encodes outcome as an integer `status_id` (1 = Success, 2 = Failure) — CIM wants a string `action = success` / `failure`.
- And nothing has tagged the event as `authentication`.

Because none of those names or tags line up, the data model's constraints match zero of your events. So `| tstats ... from datamodel=Authentication` returns nothing for Security Lake, every ES dashboard and correlation search that keys off that data model silently skips it, and risk-based alerting never sees it. The data is sitting right there in the index — it's just not wearing the uniform the ES machinery checks for at the door. That's the "searchable but invisible" split the ladder shows: visible to *you* in raw search, invisible to the *data-model-driven* layer above the amber line.

## What the OCSF→CIM mapping layer actually is

It's a set of search-time knowledge objects (no re-indexing) that translate one schema to the other. Three moving parts:

Field renaming — `FIELDALIAS` or `EVAL` statements in `props.conf` that alias OCSF fields to CIM fields (`actor.user.name` → `user`, `src_endpoint.ip` → `src`, `dst_endpoint.ip` → `dest`).

Value normalization — `EVAL`s that convert OCSF integer enums into CIM's controlled vocabulary (e.g. `action = case(status_id==1,"success", status_id==2,"failure")`). OCSF's `class_uid`/`activity_id` similarly get mapped to CIM concepts.

Tagging — `eventtypes.conf` + `tags.conf` that attach the CIM tag the data model requires, keyed off the OCSF class. For example, events where `class_uid=3002` (Authentication) get `eventtype=authentication` which carries `tag=authentication`.

Once those exist, the same events start matching the data model constraints, flow into the accelerated model, and every piece of ES content built on it lights up automatically — no changes to the correlation searches themselves. Conceptually:

```spl
| tstats count from datamodel=Authentication where Authentication.app=aws:asl by Authentication.user
```

goes from returning nothing to returning your Security Lake auth events.

The reassuring part for you: because OCSF is already structured and predictable, this is a *schema-to-schema* mapping, not the usual "parse a pile of unstructured logs" grind. Each OCSF class maps fairly mechanically to a CIM model (Authentication → 3002, Network Activity → 400x → Network Traffic, and so on), so it's bounded work — one mapping set per OCSF class you care about.

One planning note worth weighing: you can do this normalization *in Splunk* (search-time knowledge objects, flexible, no data movement) or *upstream in the pipeline* (Vector/an ingest processor rewriting fields before they land, which trims what you index but bakes the mapping into the pipeline). For a regulated ES environment I'd usually start with the Splunk-side search-time approach since it's reversible and doesn't touch the data-in-motion path — but the upstream option becomes attractive if Security Lake volume is inflating your license.

Want me to draft the actual starter `props.conf`/`transforms.conf`/`eventtypes.conf`/`tags.conf` for the two or three OCSF classes you'd most likely care about first (Authentication 3002, Network Activity 4001, and API/CloudTrail-style Account Change events), so you have a concrete mapping skeleton to build on?
