

AWS documents `traffic.bytes` as the OCSF byte-count field for Security Lake VPC Flow events, and Splunk maps it to the CIM field `bytes`. [AWS Security Lake example](https://docs.aws.amazon.com/security-lake/latest/userguide/vpc-query-examples-sourceversion2.html), [Splunk OCSF mapping](https://splunk.github.io/ocsf_cim_addon_for_splunk/mappings/4001/).

## Correct top-source-talkers query

Replace `<security_lake_index>` with your actual index name:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| eval byte_count=tonumber('traffic.bytes')
| where isnotnull('src_endpoint.ip') AND isnotnull(byte_count)
| stats count AS flows sum(byte_count) AS total_bytes BY 'src_endpoint.ip'
| sort 10 - total_bytes
| eval total_MB=round(total_bytes/1024/1024,2)
| rename 'src_endpoint.ip' AS source_ip
| table source_ip flows total_bytes total_MB
```

This means:

1. Find Security Lake Network Activity events.
2. Convert `traffic.bytes` to a number.
3. Remove events missing an IP address or byte count.
4. Group events by source IP.
5. Add the bytes for each source IP.
6. Return the ten largest talkers.

## Why the original query does not show top talkers

Your query:

```spl
| stats sum('traffic.bytes') AS bytes
```

calculates only one total for all events. It does not know which field defines a “talker.”

You need:

```spl
| stats sum('traffic.bytes') AS total_bytes BY 'src_endpoint.ip'
```

Also, this is invalid if the comma is part of your SPL:

```spl
| stats sum('traffic.bytes') AS bytes,
```

There should be no trailing comma.

## First confirm the fields contain data

Run this before attempting aggregation:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| table _time class_uid 'metadata.product.name'
        'src_endpoint.ip' 'dst_endpoint.ip'
        'src_endpoint.port' 'dst_endpoint.port'
        'traffic.bytes'
| head 20
```

You should see values similar to:

| src_endpoint.ip | dst_endpoint.ip | traffic.bytes |
| --------------- | --------------- | ------------: |
| 10.1.1.25       | 10.2.5.10       |          6845 |
| 10.1.1.30       | 8.8.8.8         |          1250 |

If `traffic.bytes` is blank, `stats sum()` has nothing to calculate.

## Check how many events have the required fields

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| stats
    count AS total_events
    count('traffic.bytes') AS events_with_bytes
    count('src_endpoint.ip') AS events_with_source_ip
    count('dst_endpoint.ip') AS events_with_destination_ip
```

Interpretation:

* `total_events > 0`, but `events_with_bytes = 0`: byte field is missing or not extracted.
* `events_with_bytes > 0`, but `events_with_source_ip = 0`: source IP extraction is the problem.
* Both fields have values: the top-talker query should work.

## If the fields are not being extracted

Try extracting the JSON fields temporarily with `spath`:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| table _time 'src_endpoint.ip' 'dst_endpoint.ip' 'traffic.bytes'
| head 20
```

Then test:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| eval byte_count=tonumber('traffic.bytes')
| stats sum(byte_count) AS total_bytes count AS flows BY 'src_endpoint.ip'
| sort 10 - total_bytes
```

If adding `spath` makes the query work, the problem is with the permanent search-time field extraction on your Search Head. The Splunk Add-on for AWS provides `aws:asl`, but Splunk currently lists this sourcetype as having no native CIM mapping. The separate OCSF-CIM Add-on maps class 4001 fields such as `traffic.bytes` to `bytes` and `src_endpoint.ip` to `src_ip`. [Splunk source-type reference](https://splunk.github.io/splunk-add-on-for-amazon-web-services/DataTypes/).

## Other useful top-talker queries

Top destination IPs:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| eval byte_count=tonumber('traffic.bytes')
| stats sum(byte_count) AS total_bytes count AS flows BY 'dst_endpoint.ip'
| sort 10 - total_bytes
| eval total_MB=round(total_bytes/1024/1024,2)
```

Top source-to-destination conversations:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| eval byte_count=tonumber('traffic.bytes')
| stats sum(byte_count) AS total_bytes count AS flows
    BY 'src_endpoint.ip' 'dst_endpoint.ip' 'dst_endpoint.port'
| sort 20 - total_bytes
| eval total_MB=round(total_bytes/1024/1024,2)
```

Because `class_uid=4001` can contain multiple network products, first see which products are included:

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| stats count BY 'metadata.product.name'
| sort - count
```

Then filter to the exact product—for example, only VPC Flow Logs—to avoid mixing or double-counting different network sources. Field names containing periods should be single-quoted inside commands such as `eval` and `stats`. [Splunk quotation rules](https://help.splunk.com/?resourceId=SCS_Search_Quotations).
