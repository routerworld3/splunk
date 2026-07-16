

---

This configuration file is for **Vector** (a high-performance observability data pipeline), which is acting as an intermediary forwarder here.

Even though it is sitting on a Splunk forwarder instance or sending to one, this specific file sets up two isolated data pipelines that **pull Kubernetes logs from AWS SQS queues** and **push them into Splunk** via the HTTP Event Collector (HEC).

Here is a breakdown of exactly how it works, separated into its two main components: **Sources** (where the data comes from) and **Sinks** (where the data goes).

---

## 1. Sources: Pulling Data from AWS

The `sources` section defines where Vector looks for incoming log data. You have two distinct environments set up in AWS GovCloud (`us-gov-west-1`):

### Pipeline A: Non-Production / Testing

* **`type: aws_sqs`**: Vector is monitoring an Amazon Simple Queue Service (SQS) queue. In a Kubernetes setup, this usually means logs are shipped from K8s to an SQS queue first to handle spikes in traffic without losing data.
* **`queue_url`**: The exact AWS SQS queue Vector is polling for messages.
* **`auth.assume_role`**: Instead of using static, insecure hardcoded AWS keys, Vector is securely assuming an IAM Role via AWS STS to grant it temporary permissions to read from that SQS queue.

### Pipeline B: Production

* Does the exact same thing as the testing/non-production pipeline, but points to a completely separate AWS account and queue dedicated to your **Production** Kubernetes environment.

---

## 2. Sinks: Sending Data to Splunk

The `sinks` section defines the destinations for the collected logs. Both sinks use **Splunk HEC (HTTP Event Collector)** over HTTPS to ship the logs locally.

### Destination A: Non-Production / Testing Splunk Sink

* **`inputs`**: This explicitly links this sink to the non-production source defined above.
* **`endpoint: "[https://127.0.0.1:8088](https://127.0.0.1:8088)"`**: It sends the logs to localhost on port 8088. This indicates that a Splunk Forwarder or Indexer is running *on the exact same machine* as this Vector instance.
* **`default_token`**: The unique HEC token used to authenticate against the Splunk HTTP Event Collector.
* **`index`**: Tells Splunk to store these logs in the specific non-production/testing index (e.g., `customer_rdte`).
* **`sourcetype: vector_raw`**: Sets the Splunk metadata `sourcetype` to `vector_raw` for easier parsing and searching later.
* **`encoding`**: Converts the log data into a neatly formatted, readable JSON payload (`pretty: true`) before handing it to Splunk.
* **`tls.verify_certificate: false`**: Disables SSL certificate verification. This is common when sending to `127.0.0.1` using a self-signed certificate, though it should be handled with care in strictly locked-down environments.

### Destination B: Production Splunk Sink

* Mirrors the testing configuration but maps the production source to the production Splunk environment.
* It routes the data to a different Splunk index (e.g., `customer_prod`) using a different HEC authentication token to keep production data completely separated from development/testing data.

---

### Summary of the Flow

```
[AWS SQS: Testing Queue] ---> [Vector Source: Testing] ---> [Vector Sink] ---> [Splunk HEC: Testing Index]
[AWS SQS: Prod Queue]    ---> [Vector Source: Prod]    ---> [Vector Sink] ---> [Splunk HEC: Production Index]

```

This is a highly scalable, decoupled architecture. If your Splunk instance temporarily goes down, the logs will safely pool up in AWS SQS rather than getting lost, and Vector will catch up once Splunk is responsive again.
