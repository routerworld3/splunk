This XML file does not appear to have any style information associated with it. The document tree is shown below.
```xml
<form version="1.1" theme="dark">
<label>VPC Flow Analysis (OCSF / Security Lake)</label>
<description>OCSF-native VPC Flow Log dashboard. Data source: sourcetype=aws:asl, Network Activity (class_uid=4001). Handles both OCSF 1.0 (disposition) and OCSF 1.1 (action) field naming.</description>
<fieldset submitButton="false" autoRun="true">
<input type="time" token="tp" searchWhenChanged="true">
<label>Time Range</label>
<default>
<earliest>-4h@m</earliest>
<latest>now</latest>
</default>
</input>
<input type="text" token="idx" searchWhenChanged="true">
<label>Index</label>
<default>*</default>
</input>
<input type="dropdown" token="acct" searchWhenChanged="true">
<label>AWS Account</label>
<choice value="*">All</choice>
<default>*</default>
<fieldForLabel>account</fieldForLabel>
<fieldForValue>account</fieldForValue>
<search>
<query>index=$idx$ sourcetype=aws:asl class_uid=4001 | stats count by cloud.account.uid | rename cloud.account.uid as account</query>
<earliest>$tp.earliest$</earliest>
<latest>$tp.latest$</latest>
</search>
</input>
<input type="dropdown" token="verdict" searchWhenChanged="true">
<label>Traffic Verdict</label>
<choice value="*">All</choice>
<choice value="Allowed">Allowed</choice>
<choice value="Denied">Denied</choice>
<default>*</default>
</input>
</fieldset>
<!--  Base search: OCSF Network Activity (VPC Flow-origin).
       verdict normalizes OCSF 1.1 action / OCSF 1.0 disposition / raw ACCEPT-REJECT  -->
<search id="base_flow">
<query>index=$idx$ sourcetype=aws:asl class_uid=4001 cloud.account.uid=$acct$ | eval src_ip='src_endpoint.ip', src_port='src_endpoint.port', dest_ip='dst_endpoint.ip', dest_port='dst_endpoint.port' | eval iface=coalesce('src_endpoint.interface_uid', 'dst_endpoint.interface_uid') | eval proto_num='connection_info.protocol_num' | eval protocol=case(proto_num=6,"TCP", proto_num=17,"UDP", proto_num=1,"ICMP", proto_num=58,"ICMPv6", true(), "proto_".tostring(proto_num)) | eval direction=coalesce('connection_info.direction', "unknown") | eval bytes=coalesce('traffic.bytes', 0), packets=coalesce('traffic.packets', 0) | eval verdict=case( coalesce(action, disposition) IN ("Allowed","ALLOWED","Allow"), "Allowed", coalesce(action, disposition) IN ("Denied","DENIED","Blocked","Deny"), "Denied", true(), coalesce(action, disposition, "Unknown")) | search verdict=$verdict$</query>
<earliest>$tp.earliest$</earliest>
<latest>$tp.latest$</latest>
</search>
<row>
<panel>
<title>Total Flow Records</title>
<single>
<search base="base_flow">
<query>| stats count</query>
</search>
<option name="drilldown">none</option>
<option name="useColors">0</option>
</single>
</panel>
<panel>
<title>Denied Flows</title>
<single>
<search base="base_flow">
<query>| search verdict=Denied | stats count</query>
</search>
<option name="drilldown">none</option>
<option name="rangeColors">["0x53a051","0xf8be34","0xdc4e41"]</option>
<option name="rangeValues">[0,1000]</option>
<option name="useColors">1</option>
</single>
</panel>
<panel>
<title>Total Traffic (GB)</title>
<single>
<search base="base_flow">
<query>| stats sum(bytes) as b | eval gb=round(b/1024/1024/1024, 2) | fields gb</query>
</search>
<option name="drilldown">none</option>
<option name="useColors">0</option>
</single>
</panel>
<panel>
<title>Distinct Source IPs</title>
<single>
<search base="base_flow">
<query>| stats dc(src_ip)</query>
</search>
<option name="drilldown">none</option>
<option name="useColors">0</option>
</single>
</panel>
<panel>
<title>Distinct Dest Ports</title>
<single>
<search base="base_flow">
<query>| stats dc(dest_port)</query>
</search>
<option name="drilldown">none</option>
<option name="useColors">0</option>
</single>
</panel>
</row>
<row>
<panel>
<title>Flow Volume Over Time by Verdict</title>
<chart>
<search base="base_flow">
<query>| timechart count by verdict</query>
</search>
<option name="charting.chart">column</option>
<option name="charting.chart.stackMode">stacked</option>
<option name="charting.fieldColors">{"Allowed":"0x53a051","Denied":"0xdc4e41"}</option>
</chart>
</panel>
<panel>
<title>Bytes Over Time by Direction</title>
<chart>
<search base="base_flow">
<query>| timechart sum(bytes) as bytes by direction</query>
</search>
<option name="charting.chart">area</option>
<option name="charting.chart.stackMode">stacked</option>
</chart>
</panel>
</row>
<row>
<panel>
<title>Top Talkers (Source to Destination by Bytes)</title>
<table>
<search base="base_flow">
<query>| stats sum(bytes) as total_bytes, sum(packets) as total_packets, count as flows by src_ip dest_ip | eval MB=round(total_bytes/1024/1024, 2) | sort - total_bytes | head 15 | table src_ip dest_ip MB total_packets flows</query>
</search>
<option name="drilldown">cell</option>
</table>
</panel>
<panel>
<title>Top Destination Ports</title>
<chart>
<search base="base_flow">
<query>| stats count by dest_port protocol | sort - count | head 10 | eval port=protocol."/".dest_port | fields port count</query>
</search>
<option name="charting.chart">bar</option>
</chart>
</panel>
</row>
<row>
<panel>
<title>Top Denied Sources (Potential Scanners)</title>
<table>
<search base="base_flow">
<query>| search verdict=Denied | stats count as denied_flows, dc(dest_port) as ports_targeted, dc(dest_ip) as hosts_targeted, values(protocol) as protocols by src_ip | sort - denied_flows | head 15</query>
</search>
<option name="drilldown">cell</option>
</table>
</panel>
<panel>
<title>Denied Traffic by Source Location</title>
<map>
<search base="base_flow">
<query>| search verdict=Denied src_ip=* | iplocation src_ip | geostats count</query>
</search>
<option name="mapping.type">marker</option>
</map>
</panel>
</row>
<row>
<panel>
<title>Protocol Breakdown</title>
<chart>
<search base="base_flow">
<query>| stats count by protocol</query>
</search>
<option name="charting.chart">pie</option>
</chart>
</panel>
<panel>
<title>Recent Denied Flows</title>
<table>
<search base="base_flow">
<query>| search verdict=Denied | table _time src_ip src_port dest_ip dest_port protocol direction iface bytes packets | sort - _time | head 25</query>
</search>
<option name="drilldown">cell</option>
</table>
</panel>
</row>
</form>
```
