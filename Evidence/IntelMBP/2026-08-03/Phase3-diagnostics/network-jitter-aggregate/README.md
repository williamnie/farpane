# Sanitized Phase 3 network diagnostic

Read-only TCP connect samples were collected while the failed live run was in
progress. Hosts, addresses, peer identifiers, keys and credentials are omitted.

- Intel MBP to Mac mini direct TCP: n=40, failures=0, median=7.66ms,
  p95=156.30ms, max=157.96ms, 10 samples above 40ms.
- Intel MBP to rendezvous TCP: n=25, failures=0, median=6.74ms,
  p95=154.24ms, max=158.87ms, 6 samples above 40ms.
- Intel MBP to relay TCP: n=25, failures=0, median=4.95ms,
  p95=154.34ms, max=156.17ms, 6 samples above 40ms.
- Mac mini to rendezvous TCP: n=25, failures=0, median=2.01ms,
  p95=6.23ms, max=7.01ms, no samples above 40ms.
- Mac mini to relay TCP: n=25, failures=0, median=1.82ms,
  p95=10.58ms, max=12.45ms, no samples above 40ms.

The Mac mini used Ethernet. The Intel MBP used Wi-Fi with RSSI -33dBm and its
AWDL interface was active. These measurements isolate the periodic latency
spikes to the MBP Wi-Fi path; they do not by themselves prove which Wi-Fi
feature or access-point behavior caused the spikes.

After AWDL was disabled locally on the Intel MBP:

- Intel MBP to Mac mini direct TCP: n=40, failures=0, median=2.58ms,
  p95=3.26ms, max=3.73ms, no samples above 40ms.
- Intel MBP to relay TCP: first n=40 confirmation had median=3.94ms,
  p95=11.02ms and one 52.63ms sample; the following n=80 confirmation had
  median=3.79ms, p95=7.50ms, p99=12.13ms, max=31.32ms and no samples above
  40ms.
- AWDL remained down and inactive after the confirmation samples.

This before/after result strongly associates the periodic 150ms spikes with
the MBP AWDL/Wi-Fi path. A real H265 relay preflight is still required because
TCP connect samples are not video acceptance evidence.
