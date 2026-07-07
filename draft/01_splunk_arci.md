# Splunk Enterprise Architecture for AWS Security Operations

## 1. The simplest mental model

Splunk Enterprise has four major jobs:

```mermaid
flowchart LR
    A[Collect] --> B[Parse and Route]
    B --> C[Index and Store]
    C --> D[Search Detect Investigate]

    A --- A1[Universal Forwarder<br/>AWS APIs<br/>S3 and SQS<br/>HEC<br/>Azure Event Hubs]
    B --- B1[Heavy Forwarders<br/>Technology Add-ons]
    C --- C1[Indexer Cluster<br/>EBS and SmartStore S3]
    D --- D1[Search Head Cluster<br/>Enterprise Security]
```

1. **Collect:** Retrieve logs from AWS, MDE, servers, network devices and applications.
2. **Parse and route:** Identify event boundaries, timestamps, source types and destinations.
3. **Index and store:** Convert raw events into searchable Splunk indexes.
4. **Search and analyze:** Run searches, dashboards, alerts, threat detections and investigations.

A distributed Splunk deployment separates these functions so that collection, storage and search can scale independently. Splunk forwarders send data, indexers store and search data, and search heads coordinate user searches across the indexers. ([Splunk Docs][1])

---

# 2. Core Splunk Enterprise components

| Component                           | Primary function                                                                                             | Recommended enterprise use                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| **Universal Forwarder — UF**        | Lightweight agent that collects local files, Linux logs, Windows Event Logs and application logs             | Install on EC2 instances when host-level log collection is required          |
| **Heavy Forwarder — HF**            | Full Splunk processing tier that runs modular inputs, add-ons, parsing, filtering and routing                | Use for AWS API inputs, S3/SQS, CloudWatch, Azure Event Hubs, syslog and HEC |
| **Indexer**                         | Parses incoming events when needed, creates index buckets, stores raw data and serves searches               | Deploy as an indexer cluster across Availability Zones                       |
| **Indexer cluster manager**         | Coordinates peer replication, distributes indexer configuration and tells search heads where data is located | Exactly one active manager per indexer cluster                               |
| **Search head**                     | Accepts SPL searches, distributes work to indexers and merges results                                        | Use a cluster for production                                                 |
| **Search head cluster — SHC**       | Provides search availability and replicates dashboards, knowledge objects and scheduled searches             | Minimum three members for high availability                                  |
| **SHC captain**                     | Coordinates scheduled searches and cluster activity                                                          | Dynamically elected from the SHC members                                     |
| **SHC deployer**                    | Distributes apps and configuration bundles to the SHC                                                        | Separate instance; one deployer per SHC                                      |
| **Deployment server**               | Distributes applications and configuration to Universal Forwarders and other deployment clients              | Manage forwarders by server class                                            |
| **License manager**                 | Tracks Splunk Enterprise license allocation and ingestion volume                                             | Dedicated management instance or approved management-tier placement          |
| **Monitoring Console**              | Monitors indexing, searches, resource usage, forwarders, license consumption and cluster health              | Dedicated instance in large deployments                                      |
| **Splunk Enterprise Security — ES** | SIEM application providing security detections, risk, findings, investigations and security dashboards       | Install on the search head cluster                                           |
| **HTTP Event Collector — HEC**      | Token-authenticated HTTPS endpoint for applications and AWS Firehose                                         | Put behind an internal NLB or supported load-balancing tier                  |
| **SmartStore**                      | Uses object storage such as S3 for index bucket storage while indexers retain local cache                    | Useful for large AWS deployments and longer retention                        |

The indexer cluster manager coordinates replication and recovery but does not index external data. Peer nodes index incoming events, replicate buckets and execute search work. Splunk requires at least as many indexers as the configured replication factor. ([Splunk Docs][2])

A search head cluster normally uses a dynamically elected captain. At least three SHC members are required to retain functionality when one member fails. ([Splunk Docs][3])

---

## 3. Splunk indexing and search flow

```mermaid
sequenceDiagram
    participant Source as Log Source
    participant HF as Heavy Forwarder
    participant IDX as Indexer Cluster
    participant SH as Search Head
    participant Analyst as SOC Analyst

    Source->>HF: Send event or make event available
    HF->>HF: Identify source type and timestamp
    HF->>HF: Filter transform or route
    HF->>IDX: Forward event over TLS
    IDX->>IDX: Create searchable index bucket
    IDX->>IDX: Replicate bucket to peers

    Analyst->>SH: Run SPL search
    SH->>IDX: Distribute search
    IDX-->>SH: Return partial results
    SH->>SH: Merge and enrich results
    SH-->>Analyst: Display results or security finding
```

The search head generally does not retrieve all raw data and process it centrally. It distributes search work to indexers, which search their local buckets and return matching or aggregated results.

---

# 4. How the AWS and Microsoft data sources fit

## Recommended collection methods

| Source                                 | Preferred path                                                                         | Comments                                                                  |
| -------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Security Lake AWS-native sources       | Security Lake S3 → SQS subscriber → Splunk AWS Add-on/HF                               | OCSF and Parquet source                                                   |
| AWS Network Firewall logs              | CloudWatch Logs → Splunk AWS Add-on, or Firehose/S3 → SQS → HF                         | Network Firewall is not currently a native Security Lake source           |
| AWS Network Firewall metrics           | CloudWatch metrics API → Splunk AWS Add-on                                             | Useful for dropped packets and firewall health                            |
| MDE/XDR incidents and alerts           | Splunk Add-on for Microsoft Security/API                                               | Lower-volume security records                                             |
| MDE Advanced Hunting events            | Defender XDR Streaming API → Azure Event Hubs → Splunk Microsoft Cloud Services Add-on | High-volume endpoint telemetry                                            |
| EC2 Linux/Windows logs                 | Universal Forwarder → indexer cluster                                                  | Direct and near real-time                                                 |
| Application logs                       | UF, HEC or CloudWatch/Firehose                                                         | Choose based on application architecture                                  |
| Security Hub findings                  | Security Lake or direct EventBridge/API input                                          | Avoid duplicate ingestion                                                 |
| GuardDuty findings                     | Security Hub/Security Lake, EventBridge or AWS Add-on                                  | Choose one authoritative path                                             |
| CloudTrail, VPC Flow and Route 53 logs | Prefer Security Lake when enabled                                                      | Avoid simultaneously ingesting the same events through multiple pipelines |

Security Lake currently provides native collection for CloudTrail management and selected data events, EKS audit logs, Route 53 Resolver queries, Security Hub CSPM findings, VPC Flow Logs and WAFv2 logs. It transforms these into OCSF and Apache Parquet. AWS Network Firewall is not on that native-source list. ([AWS Documentation][4])

AWS documents a direct Network Firewall integration in which Network Firewall writes to CloudWatch Logs and the Splunk Add-on for AWS retrieves the logs and metrics. Network Firewall can also publish logs through Data Firehose. ([AWS Documentation][5])

---

## 5. Combined AWS, Security Lake, Network Firewall and MDE flow

```mermaid
flowchart TB
    subgraph AWSORG["AWS Organization"]
        subgraph MEMBERS["Member Accounts"]
            CT[CloudTrail]
            VPC[VPC Flow Logs]
            R53[Route 53 Resolver Logs]
            WAF[AWS WAF]
            EKS[EKS Audit Logs]
            SH[Security Hub CSPM]
            NFW[AWS Network Firewall]
            EC2[EC2 OS and Application Logs]
        end

        subgraph SECTOOL["Security Tooling Account"]
            SL[Amazon Security Lake<br/>OCSF and Parquet]
            SQS1[Security Lake Subscriber SQS]
            CWL[Central CloudWatch Logs]
            S3LOG[Central Logging S3]
        end
    end

    subgraph MICROSOFT["Microsoft Security"]
        MDE[Microsoft Defender XDR and MDE]
        EH[Azure Event Hubs]
    end

    subgraph SPLUNK["Splunk Enterprise on AWS"]
        HF1[Security Lake and AWS Heavy Forwarders]
        HF2[Microsoft Heavy Forwarders]
        UF[Universal Forwarders]
        IDX[Indexer Cluster]
        ES[Search Head Cluster<br/>Splunk Enterprise Security]
    end

    CT --> SL
    VPC --> SL
    R53 --> SL
    WAF --> SL
    EKS --> SL
    SH --> SL

    SL --> SQS1
    SQS1 --> HF1
    HF1 --> SL

    NFW --> CWL
    NFW --> S3LOG
    CWL --> HF1
    S3LOG --> HF1

    EC2 --> UF
    UF --> IDX

    MDE --> EH
    EH --> HF2

    HF1 --> IDX
    HF2 --> IDX
    IDX --> ES
```

The arrow from the Splunk collector back to Security Lake represents the collector assuming the subscriber role and reading the S3 objects identified by SQS notifications; Splunk is not writing those events back to Security Lake.

Microsoft recommends using the Defender XDR Streaming API to send event data to Azure Event Hubs and the Splunk Add-on for Microsoft Cloud Services to consume those events. The Splunk Add-on for Microsoft Security can also collect Defender incidents and alerts. ([Microsoft Learn][6])

---

# 6. Proof-of-concept deployment

A POC should prove:

* AWS authentication and cross-account access
* Security Lake S3/SQS ingestion
* Network Firewall log parsing
* MDE Event Hub ingestion
* OCSF and CIM field mappings
* Basic cross-source correlation
* Expected ingest volume and storage requirements

It should not be presented as highly available.

```mermaid
flowchart LR
    subgraph AWSORG["POC AWS Organization"]
        A1[Workload Account 1]
        A2[Workload Account 2]
        SEC[Security Account<br/>Security Lake]
        Q[Subscriber SQS]

        A1 --> SEC
        A2 --> SEC
        SEC --> Q
    end

    NFW[Network Firewall<br/>CloudWatch Logs] --> HF
    Q --> HF[Heavy Forwarder<br/>AWS and Microsoft Add-ons]
    HF --> SEC

    MDE[MDE Streaming API] --> EH[Azure Event Hub]
    EH --> HF

    UF[EC2 Universal Forwarder] --> SPLUNK

    HF --> SPLUNK[Single Splunk Enterprise EC2<br/>Search + Index + License + Monitoring]
    SPLUNK --> EBS[(Encrypted EBS)]
    SPLUNK --> ES[Optional ES Trial or POC]
```

## Suggested POC components

| Component                    |                      Quantity | Purpose                                    |
| ---------------------------- | ----------------------------: | ------------------------------------------ |
| Splunk Enterprise standalone |                             1 | Search, indexing, licensing and monitoring |
| Heavy Forwarder              |                             1 | AWS, Security Lake and Microsoft inputs    |
| Security Lake subscriber     | 1 per Region or rollup Region | S3/SQS access                              |
| Universal Forwarder          |              2–5 test servers | Host log validation                        |
| Encrypted EBS                |           Based on POC volume | Hot/warm storage                           |
| Enterprise Security          |                      Optional | Validate SIEM use cases                    |

### POC limitations

* No search-head availability.
* No indexer replication.
* Collector failure stops cloud ingestion temporarily.
* Local storage is a single-node risk.
* Maintenance causes outages.
* It does not accurately validate large-scale search concurrency.

---

# 7. Enterprise-grade Splunk deployment in AWS

A strong enterprise design separates the platform into four tiers:

1. **Access and search tier**
2. **Collection and input tier**
3. **Indexing and storage tier**
4. **Management tier**

Splunk’s validated AWS high-availability architecture places indexers and search-head-cluster members across three Availability Zones and places a load balancer in front of the search heads. SmartStore can use S3 as remote bucket storage. ([Splunk Docs][7])

```mermaid
flowchart TB
    USERS[SOC Analysts and Administrators]
    ALB[Internal ALB<br/>Splunk Web 8000 or 443]

    subgraph AWS["Splunk Security Tooling Account - Three AZs"]
        subgraph SEARCH["Search Tier"]
            SH1[Search Head 1<br/>AZ-A]
            SH2[Search Head 2<br/>AZ-B]
            SH3[Search Head 3<br/>AZ-C]
            ES[Splunk Enterprise Security]
        end

        subgraph INPUT["Collection Tier"]
            NLB[Internal NLB<br/>HEC and Syslog Inputs]
            HF1[Heavy Forwarder 1<br/>AZ-A]
            HF2[Heavy Forwarder 2<br/>AZ-B]
            HF3[Heavy Forwarder 3<br/>AZ-C]
        end

        subgraph INDEX["Indexer Cluster"]
            I1[Indexer 1<br/>AZ-A]
            I2[Indexer 2<br/>AZ-B]
            I3[Indexer 3<br/>AZ-C]
            I4[Indexer 4<br/>AZ-A]
            I5[Indexer 5<br/>AZ-B]
            I6[Indexer 6<br/>AZ-C]
        end

        subgraph MGMT["Management Tier"]
            CM[Cluster Manager<br/>One Active]
            DEP[SHC Deployer]
            DS[Deployment Server]
            LM[License Manager]
            MC[Monitoring Console]
        end

        CACHE[(Local NVMe or EBS Cache)]
        SMART[(Dedicated S3 SmartStore Bucket)]
    end

    USERS --> ALB
    ALB --> SH1
    ALB --> SH2
    ALB --> SH3

    SH1 --- SH2
    SH2 --- SH3
    SH3 --- SH1
    ES --- SH1
    ES --- SH2
    ES --- SH3

    NLB --> HF1
    NLB --> HF2
    NLB --> HF3

    HF1 --> I1
    HF1 --> I2
    HF2 --> I3
    HF2 --> I4
    HF3 --> I5
    HF3 --> I6

    I1 --- I2
    I2 --- I3
    I3 --- I4
    I4 --- I5
    I5 --- I6
    I6 --- I1

    SH1 --> I1
    SH2 --> I3
    SH3 --> I5

    CM --> I1
    CM --> I2
    CM --> I3
    CM --> I4
    CM --> I5
    CM --> I6

    DEP --> SH1
    DEP --> SH2
    DEP --> SH3

    DS --> HF1
    DS --> HF2
    DS --> HF3

    LM --> I1
    LM --> I3
    LM --> I5

    MC -.monitor.-> SH1
    MC -.monitor.-> HF1
    MC -.monitor.-> I1
    MC -.monitor.-> CM

    I1 --> CACHE
    I2 --> CACHE
    I3 --> CACHE
    I4 --> CACHE
    I5 --> CACHE
    I6 --> CACHE

    I1 --> SMART
    I2 --> SMART
    I3 --> SMART
    I4 --> SMART
    I5 --> SMART
    I6 --> SMART
```

## Important indexer settings

### Replication factor

The **replication factor**, or RF, determines the number of copies of raw index data.

For example:

* RF=3 means three copies of each bucket.
* The cluster can generally tolerate up to RF minus one peer failures without losing all copies of a bucket.
* At least three indexer peers are required for RF=3. ([Splunk Docs][8])

### Search factor

The **search factor**, or SF, determines how many bucket copies have complete searchable index files.

A common starting point is:

```text
Replication Factor = 3
Search Factor      = 2
```

The correct values should come from the required failure model, ingest rate, search workload and storage architecture. Splunk documents SF=2 as the default for an indexer cluster. ([Splunk Docs][9])

---

# 8. SmartStore and Security Lake are different

These two S3 storage systems should not be combined.

```mermaid
flowchart LR
    SL[Security Lake S3 Bucket<br/>OCSF Parquet source data]
    SPLUNK[Splunk Indexers]
    SS[SmartStore S3 Bucket<br/>Splunk index buckets]

    SL -->|Read and ingest selected events| SPLUNK
    SPLUNK -->|Write Splunk bucket format| SS
```

## Security Lake S3

* Owned and managed as the AWS security data lake.
* Contains OCSF-normalized Parquet.
* Accessed through Security Lake subscriber permissions.
* Can provide long-term source retention.

## SmartStore S3

* Owned by the Splunk platform.
* Contains Splunk index buckets and metadata.
* Used by Splunk indexers as remote index storage.
* Must not be modified or queried as though it were ordinary log files.

SmartStore supports AWS S3 remote storage when the indexers are hosted on AWS. All indexer peers must use consistent SmartStore index configurations. ([Splunk Docs][10])

---

# 9. Security Lake across multiple AWS accounts

Within one AWS Organization, the management account designates a **Security Lake delegated administrator**. That administrator can enable sources for member accounts, automatically onboard new accounts and grant subscribers access to the organization’s data. ([AWS Documentation][11])

```mermaid
flowchart TB
    MGMT[AWS Organizations<br/>Management Account]
    DA[Security Lake Delegated Administrator<br/>Security Tooling Account]

    subgraph MEMBERS["Organization Member Accounts"]
        A1[Account A]
        A2[Account B]
        A3[Account C]
    end

    SL[Regional Security Lake<br/>S3 + Glue + OCSF]
    ROLLUP[Optional Rollup Region]
    SUB[Splunk Subscriber]
    SQS[Subscriber SQS]
    HF[Splunk Heavy Forwarders]
    IDX[Splunk Indexer Cluster]

    MGMT -->|Designates| DA
    DA -->|Enables collection| A1
    DA -->|Enables collection| A2
    DA -->|Enables collection| A3

    A1 --> SL
    A2 --> SL
    A3 --> SL
    SL --> ROLLUP
    ROLLUP --> SUB
    SUB --> SQS
    SQS --> HF
    HF -->|Assume subscriber role and read objects| ROLLUP
    HF --> IDX
```

A subscriber receives access only to the selected sources and Region. A rollup Region can aggregate contributing Regions so that Splunk does not need a completely independent subscriber for every contributing Region. Security Lake can notify a data-access subscriber through SQS as new S3 objects are created. ([AWS Documentation][12])

---

# 10. Multiple Security Lakes across different AWS Organizations

An important boundary is:

> A Security Lake delegated administrator manages one AWS Organization, not every AWS Organization in the enterprise.

Therefore, with three separate AWS Organizations, there will normally be three independent Security Lake environments.

## Pattern A: One central Splunk deployment ingests all organizations

This is usually the best design when one SOC is authorized to hold and analyze all organizations’ logs.

```mermaid
flowchart TB
    subgraph ORG1["AWS Organization 1"]
        SL1[Security Lake 1<br/>Rollup Region]
        Q1[Subscriber SQS 1]
        SL1 --> Q1
    end

    subgraph ORG2["AWS Organization 2"]
        SL2[Security Lake 2<br/>Rollup Region]
        Q2[Subscriber SQS 2]
        SL2 --> Q2
    end

    subgraph ORG3["AWS Organization 3"]
        SL3[Security Lake 3<br/>Rollup Region]
        Q3[Subscriber SQS 3]
        SL3 --> Q3
    end

    subgraph SPLUNK["Central Splunk Security Account"]
        HF1[Collector Pair<br/>Organization 1]
        HF2[Collector Pair<br/>Organization 2]
        HF3[Collector Pair<br/>Organization 3]
        IDX[Central Indexer Cluster]
        SHC[Central SHC and Enterprise Security]
    end

    Q1 --> HF1
    HF1 -->|Assume Org-1 subscriber role| SL1

    Q2 --> HF2
    HF2 -->|Assume Org-2 subscriber role| SL2

    Q3 --> HF3
    HF3 -->|Assume Org-3 subscriber role| SL3

    HF1 --> IDX
    HF2 --> IDX
    HF3 --> IDX
    IDX --> SHC
```

Each organization creates its own:

* Splunk subscriber.
* External ID.
* Subscriber IAM role or Security Lake-managed access.
* SQS subscription endpoint.
* Source selection.
* Regional or rollup-region configuration.

The Splunk collector maintains separate AWS account definitions and credentials for each organization.

### Add organizational context at ingestion

Every event should retain or receive fields such as:

```text
aws_account_id
aws_region
aws_org_id
security_lake_id
mission_owner
environment
data_classification
source_category
```

This permits:

* Role-based index access.
* Organization-specific dashboards.
* Mission-owner reporting.
* Cost allocation.
* Separate retention.
* Investigation across organizations.

A useful index strategy could be:

```text
aws_security_org1
aws_security_org2
aws_security_org3
mde
network_firewall
splunk_internal
```

For very large deployments, separate indexes by data type and enforce organization boundaries through metadata and Splunk roles rather than creating hundreds of small indexes.

---

## Pattern B: Independent Splunk deployment per organization

Use this when organizations require data sovereignty, independent administration or limited cross-boundary connectivity.

```mermaid
flowchart TB
    subgraph O1["Organization 1"]
        SL1[Security Lake 1]
        SP1[Splunk Deployment 1]
        SL1 --> SP1
    end

    subgraph O2["Organization 2"]
        SL2[Security Lake 2]
        SP2[Splunk Deployment 2]
        SL2 --> SP2
    end

    subgraph O3["Organization 3"]
        SL3[Security Lake 3]
        SP3[Splunk Deployment 3]
        SL3 --> SP3
    end

    GLOBAL[Central Federated Search Head]

    GLOBAL -->|Federated search| SP1
    GLOBAL -->|Federated search| SP2
    GLOBAL -->|Federated search| SP3
```

This reduces central duplication and preserves organizational control, but cross-organization searches are slower and depend on every remote provider being reachable and healthy.

---

# 11. How Splunk Federated Search works

Splunk-to-Splunk Federated Search allows one Splunk deployment to query another Splunk deployment without ingesting the remote data into the local indexer cluster.

```mermaid
sequenceDiagram
    participant Analyst
    participant FSH as Federated Search Head
    participant RP as Remote Federated Provider
    participant IDX as Remote Indexer Cluster

    Analyst->>FSH: Submit federated SPL search
    FSH->>RP: Authenticated REST request over TLS 8089
    RP->>IDX: Execute search near remote data
    IDX-->>RP: Return matching or aggregated results
    RP-->>FSH: Return search results
    FSH->>FSH: Merge local and remote results
    FSH-->>Analyst: Display combined result
```

Communication between the local search head and remote provider uses an internal Splunk REST API. TCP 8089 is the standard Splunk management port used for this connection. A dedicated service account and appropriately limited Splunk role should be used on each remote provider. ([Splunk Docs][13])

## What federation does

* Leaves remote index data at the remote deployment.
* Sends search instructions to the remote search head.
* Executes the search against the remote indexers.
* Returns results to the initiating search head.
* Allows central analysts to search multiple Splunk deployments.

## What federation does not do

* It does not replicate remote indexes.
* It does not provide disaster recovery for the remote deployment.
* It does not make remote data locally available when the provider is unreachable.
* It does not eliminate remote search compute requirements.
* It does not automatically make every ES detection federation-compatible.

---

## Standard mode versus transparent mode

### Standard mode

The user explicitly searches a federated index associated with a remote provider.

Best when:

* The remote environment should be clearly identified.
* Different permissions apply to different providers.
* Index names overlap across organizations.
* Administrators want controlled, explicit federation.

Conceptually:

```text
Central search
    local AWS index
    + Org-1 federated index
    + Org-2 federated index
```

### Transparent mode

Existing searches can reference indexes with less awareness of whether the data is local or remote.

Best when:

* Moving data or searches between deployments.
* Local and remote deployments have carefully aligned knowledge objects.
* Existing dashboards should require fewer changes.

Transparent mode is not supported for every combination of Splunk Enterprise and Splunk Cloud, so compatibility must be validated before selecting it. ([Splunk Docs][14])

---

## Recommended private federation network

```mermaid
flowchart LR
    FSH[Federated Search Head]
    TGW[Transit Gateway or Approved WAN]
    PL[PrivateLink Endpoint<br/>Optional]
    NLB[Internal NLB<br/>TCP 443 or 8089]
    RP1[Remote Search Head 1]
    RP2[Remote Search Head 2]
    RIDX[Remote Indexer Cluster]

    FSH -->|TLS| TGW
    TGW --> PL
    PL --> NLB
    NLB --> RP1
    NLB --> RP2
    RP1 --> RIDX
    RP2 --> RIDX
```

For a private cross-account or cross-organization design, an NLB with PrivateLink is preferable when the goal is simple TCP/TLS pass-through to the Splunk management service. Limit the service account’s indexes and search capabilities to the data the central SOC is authorized to search.

---

# 12. Two different meanings of “federated” with Security Lake

Do not confuse these technologies.

## Splunk-to-Splunk Federated Search

```text
Splunk search head
        ↓ TCP 8089
Remote Splunk search head
        ↓
Remote Splunk indexers
```

This is relevant to self-managed Splunk Enterprise deployments.

## Federated Search for Amazon S3 / Security Lake

```text
Splunk Cloud
      ↓
Glue Data Catalog and Security Lake
      ↓
Parquet data in S3
```

This searches S3 data without first fully indexing it into Splunk. Splunk documents the Security Lake “Federated Analytics” capability as a Splunk Cloud Platform feature. It can retain recent Security Lake data in local “data lake indexes” for frequent detections while searching older data remotely for threat hunting. ([Splunk Docs][15])

For your AWS GovCloud/DoD-oriented environment, this distinction is particularly important: Splunk currently documents Federated Analytics as unavailable for FedRAMP Moderate, FedRAMP High and DoD IL5 Splunk Cloud deployments. A self-managed Splunk Enterprise design should therefore plan to consume Security Lake through its S3/SQS subscriber pipeline unless Splunk confirms another supported offering for the target environment. ([Splunk Docs][15])

---

# 13. Main Splunk ports

|                   Port | Purpose                                                       |
| ---------------------: | ------------------------------------------------------------- |
|                TCP 443 | Recommended user-facing HTTPS/load-balancer entry point       |
|               TCP 8000 | Splunk Web default                                            |
|               TCP 8089 | Splunk management API and Splunk federated search             |
|               TCP 8088 | HTTP Event Collector                                          |
|               TCP 9997 | Splunk-to-Splunk event forwarding                             |
|        TCP 8080 / 9887 | Indexer cluster replication-related communication             |
| TCP 8081 / 9887 / 8181 | Search head cluster communication, depending on configuration |

Splunk documents 8089 as the management and REST port, 8000 for Splunk Web, 9997 for forwarder ingestion and 8088 for HEC. Cluster communication requires additional internal ports. ([Splunk Docs][16])

---

# 14. Recommended enterprise design for your environment

```mermaid
flowchart TB
    SOURCES["Multiple AWS Organizations<br/>MDE and AWS Security Services"]
    LAKES["One Security Lake per AWS Organization<br/>Rollup Regions where supported"]
    COLLECT["Dedicated HA Collection Tier<br/>AWS HF Pair and Microsoft HF Pair"]
    INDEX["Six or More Indexers<br/>Three AZ Cluster<br/>RF 3 / SF 2 starting model"]
    SMART["Dedicated SmartStore S3<br/>KMS encrypted"]
    SEARCH["Three Search Heads<br/>Internal ALB<br/>Splunk Enterprise Security"]
    MGMT["Dedicated Management Tier<br/>CM, Deployer, DS, LM, MC"]
    FED["Optional Federated Search<br/>for isolated Splunk deployments"]

    SOURCES --> LAKES
    SOURCES --> COLLECT
    LAKES --> COLLECT
    COLLECT --> INDEX
    INDEX --> SMART
    SEARCH --> INDEX
    MGMT -.manages.-> COLLECT
    MGMT -.manages.-> INDEX
    MGMT -.manages.-> SEARCH
    SEARCH --> FED
```

## Final recommendations

1. **Use Security Lake as the normalized AWS security source**, but continue direct pipelines for Network Firewall, MDE, operating-system logs and unsupported sources.

2. **Use SQS-driven collection rather than broad periodic S3 polling.** SQS tells the collector which new Security Lake objects are ready, reducing repeated listing and polling. Security Lake supports SQS notification for data-access subscribers. ([AWS Documentation][12])

3. **Avoid duplicate ingestion.** Do not ingest CloudTrail, VPC Flow, WAF or Security Hub through Security Lake and an independent direct pipeline unless the duplicate has a documented latency or operational requirement.

4. **Keep collection add-ons off the production SHC.** Run AWS and Microsoft modular inputs on dedicated heavy forwarders so that collection failures do not consume search-head resources.

5. **Use three Availability Zones for the indexer and search tiers.** Deploy at least three search heads and enough indexers to satisfy the replication factor plus indexing and search capacity.

6. **Use separate S3 buckets for Security Lake, centralized raw-log archives and SmartStore.** Each has a different format, lifecycle and access model.

7. **For multiple AWS Organizations, create a separate Security Lake subscriber per organization and rollup Region.** Centralize in one Splunk deployment only when data-sharing policy permits it.

8. **Use Splunk-to-Splunk federation when an organization must retain its own Splunk deployment.** Do not use federation as a substitute for central ingestion when frequent ES detections must run against all events.

9. **Normalize both schemas.** Security Lake uses OCSF while Splunk Enterprise Security typically depends heavily on Splunk CIM data models. Splunk recommends the OCSF-CIM Add-on or equivalent mappings when using OCSF data with Splunk and Enterprise Security. ([Splunk Docs][17])

10. **Treat Splunk as a security workload.** Use private subnets, VPC endpoints, KMS encryption, IAM instance roles, Secrets Manager, TLS for forwarding, restricted management ports, SSM administration and centralized monitoring of Splunk’s own `_internal` and audit indexes.

[1]: https://help.splunk.com/en/splunk-enterprise/administer/distributed-deployment-manual/9.3/overview-of-splunk-enterprise-distributed-deployments/components-and-the-data-pipeline?utm_source=chatgpt.com "Components and the data pipeline - Splunk Enterprise"
[2]: https://help.splunk.com/en/splunk-enterprise/administer/manage-indexers-and-indexer-clusters/10.4/overview-of-indexer-clusters-and-index-replication/the-basics-of-indexer-cluster-architecture "The basics of indexer cluster architecture | Splunk Enterprise (last updated 2026-05-14T15:26:02.958Z)"
[3]: https://help.splunk.com/en/splunk-enterprise/administer/distributed-search/9.3/overview-of-search-head-clustering/search-head-clustering-architecture?utm_source=chatgpt.com "Search head clustering architecture - Splunk Enterprise"
[4]: https://docs.aws.amazon.com/security-lake/latest/userguide/internal-sources.html "Collecting data from AWS services in Security Lake - Amazon Security Lake"
[5]: https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/view-aws-network-firewall-logs-and-metrics-by-using-splunk.html "View AWS Network Firewall logs and metrics by using Splunk - AWS Prescriptive Guidance"
[6]: https://learn.microsoft.com/en-us/defender-xdr/configure-siem-defender "Integrate your SIEM tools with Microsoft Defender XDR - Microsoft Defender XDR | Microsoft Learn"
[7]: https://help.splunk.com/en/splunk-enterprise/splunk-validated-architectures/splunk-platform-indexing-and-search/aws-byol-high-availability "AWS BYOL high availability | Splunk Enterprise, Splunk Cloud Platform (last updated 2026-02-12T16:51:32.124Z)"
[8]: https://help.splunk.com/en/splunk-enterprise/administer/manage-indexers-and-indexer-clusters/10.4/how-indexer-clusters-work/replication-factor?utm_source=chatgpt.com "Replication factor | Splunk Enterprise (last updated 2026- ..."
[9]: https://help.splunk.com/en/splunk-enterprise/administer/manage-indexers-and-indexer-clusters/10.4/how-indexer-clusters-work/search-factor?utm_source=chatgpt.com "Search factor | Splunk Enterprise (last updated 2026-05-14T15: ..."
[10]: https://help.splunk.com/en/splunk-enterprise/administer/manage-indexers-and-indexer-clusters/10.2/deploy-smartstore/smartstore-system-requirements?utm_source=chatgpt.com "SmartStore system requirements - Splunk Enterprise"
[11]: https://docs.aws.amazon.com/security-lake/latest/userguide/multi-account-management.html "Managing multiple accounts with AWS Organizations in Security Lake - Amazon Security Lake"
[12]: https://docs.aws.amazon.com/security-lake/latest/userguide/subscriber-data-access.html?utm_source=chatgpt.com "Managing data access for Security Lake subscribers"
[13]: https://help.splunk.com/en/splunk-enterprise/search/federated-search/10.4/run-federated-searches-across-other-splunk-deployments/define-a-splunk-platform-federated-provider/steps?utm_source=chatgpt.com "Steps | Splunk Cloud Platform (last updated 2026-05- ..."
[14]: https://help.splunk.com/en/splunk-enterprise-security-8/user-guide/8.5/introduction/use-federated-searches-in-transparent-mode-with-splunk-enterprise-security?utm_source=chatgpt.com "Use federated searches in transparent mode with Splunk ..."
[15]: https://help.splunk.com/en/splunk-cloud-platform/search/federated-search/9.3.2408/ingest-and-search-amazon-security-lake-datasets/about-federated-analytics?utm_source=chatgpt.com "About Federated Analytics - Splunk Cloud Platform"
[16]: https://help.splunk.com/en/splunk-enterprise/administer/inherit-a-splunk-deployment/9.3/inherited-deployment-tasks/components-and-their-relationship-with-the-network?utm_source=chatgpt.com "Components and their relationship with the network"
[17]: https://help.splunk.com/en/data-management/process-data-at-the-edge/use-edge-processors-for-splunk-cloud-platform/process-data-using-pipelines/convert-data-to-ocsf-format-using-an-edge-processor/working-with-ocsf-formatted-data-in-the-splunk-platform-and-splunk-enterprise-security?utm_source=chatgpt.com "Working with OCSF-formatted data in the Splunk platform ..."
