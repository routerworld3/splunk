Since `spath` works, build the query in this order:

1. Retrieve class `4001` events.
2. Extract nested OCSF fields.
3. Filter blocked events.
4. Display the network details.
5. Limit the final results.

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| where lower(disposition)="blocked"
| table _time metadata.product.name disposition
        src_endpoint.ip src_endpoint.port
        dst_endpoint.ip dst_endpoint.port
        connection_info.protocol_name
        traffic.bytes
| sort 0 - _time
| head 100
```

This gives you:

| Field                           | Meaning                                      |
| ------------------------------- | -------------------------------------------- |
| `_time`                         | When the event happened                      |
| `metadata.product.name`         | Product that blocked the traffic             |
| `src_endpoint.ip`               | Source IP                                    |
| `src_endpoint.port`             | Source port                                  |
| `dst_endpoint.ip`               | Destination IP                               |
| `dst_endpoint.port`             | Destination port                             |
| `connection_info.protocol_name` | TCP, UDP, ICMP, etc.                         |
| `traffic.bytes`                 | Bytes associated with the blocked connection |

Notice that `head` is now at the end. If you put `head 20` before filtering, Splunk examines only 20 arbitrary events, which might contain no blocked traffic.

### Top blocked source IPs

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| where lower(disposition)="blocked"
| eval bytes=tonumber('traffic.bytes')
| stats count AS blocked_events
        sum(bytes) AS total_blocked_bytes
        dc('dst_endpoint.ip') AS unique_destinations
        values('dst_endpoint.port') AS destination_ports
        BY src_endpoint.ip
| sort 20 - blocked_events
```

### Most frequently targeted destination IP and port

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| where lower(disposition)="blocked"
| stats count AS blocked_events
        dc('src_endpoint.ip') AS unique_sources
        values('connection_info.protocol_name') AS protocols
        BY dst_endpoint.ip dst_endpoint.port
| sort 20 - blocked_events
```

### Top blocked source-to-destination connections

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| where lower(disposition)="blocked"
| eval bytes=tonumber('traffic.bytes')
| stats count AS blocked_events
        sum(bytes) AS total_bytes
        earliest(_time) AS first_seen
        latest(_time) AS last_seen
        BY src_endpoint.ip dst_endpoint.ip dst_endpoint.port
           connection_info.protocol_name
| convert ctime(first_seen) ctime(last_seen)
| sort 20 - blocked_events
```

### Blocked traffic trend over time

```spl
index=<security_lake_index> sourcetype=aws:asl class_uid=4001
| spath
| where lower(disposition)="blocked"
| timechart span=1h count AS blocked_events
```

Start with the first query to validate the events, then use the `stats` queries to summarize them.
