# RFC 0015: 24/7 Cloud Agent Daemon, Webhook Workers, and Scheduled Bots

- Status: Proposed (Baseline Draft — Subject to Active Iteration)
- Owner: Warren Headless, Desktop, Web, iOS, and Relay
- Created: 2026-09-03
- Scope: Always-on headless daemon architecture, webhook ingestion, scheduled cron execution, mobile attention routing, and zero-friction deployment.
- Supersedes: [RFC 0011 (Cloud Runs)](0011-cloud-agent-runs.md)
- Protocol baseline: Warren protocol 2.0 with capability negotiation
- Depends on: [RFC 0006](0006-agent-activity-attention.md) (Agent activity and attention), [RFC 0009](0009-own-relay-and-public-tunnel.md) (Relay remote access), [RFC 0010](0010-ios-agent-view-presentation-parity.md) (Agent view presentation parity), [RFC 0014](0014-autonomous-engineering-pipeline.md) (Autonomous engineering pipeline)

---

## 1. Executive Summary & Core Philosophy

> **"User-friendliness is the true foundation of willingness to pay."**

Developers and engineering teams do not pay for raw LLM token consumption or complex distributed infrastructure that requires weeks of maintenance. They eagerly pay for **peace of mind, saved hours, and extreme convenience**:
- A tool that keeps working after they close their laptop lid;
- A bot that quietly catches a GitHub bug report at 2:00 AM, reproduces it in a clean worktree, verifies a fix with unit tests, and submits a polished draft PR;
- A morning briefing summarizing overnight security advisories and PR changes delivered directly to their phone.

This RFC establishes the baseline architecture for Warren's **always-on cloud execution layer**. It formally supersedes the over-engineered enterprise container/billing design of RFC 0011, replacing it with a pragmatic, user-centric model that runs seamlessly on both self-hosted servers (VPS/homelab) and future managed cloud tiers.

---

## 2. Core User Scenarios & Value Drivers

```text
               ┌────────────────────────────────────────────────────────┐
               │              Trigger Sources (24/7)                    │
               │  • Webhook: GitHub / GitLab Issue & PR Events          │
               │  • Cron: Periodic Schedules (e.g. Daily at 08:30)      │
               │  • Remote Dispatch: Laptop Closed / Mobile Task Launch │
               └──────────────────────────┬─────────────────────────────┘
                                          │
                                          ▼
                      ┌──────────────────────────────────────┐
                      │  Warren Cloud Daemon (`headless`)     │
                      │  • Always-on, persistent host        │
                      │  • Inbound Relay tunnel (RFC 0009)   │
                      │  • Executes RFC 0014 Pipelines       │
                      │  • Git Worktree isolation            │
                      └───────────────────┬──────────────────┘
                                          │
                                          ▼
                      ┌──────────────────────────────────────┐
                      │  Verified Output & Attention Alerts  │
                      │  • Clean Pull Requests on GitHub     │
                      │  • Push Notification to Warren iOS   │
                      │  • Review & Approve from Phone       │
                      └──────────────────────────────────────┘
```

### 2.1 Scenario 1: The "Laptop Lid" Problem (Off-the-Grid Execution)
* **The Pain**: A developer starts a heavy task (e.g., extensive refactoring across 30 files, building complex artifacts, running 2,000 integration tests) on their MacBook. When it is time to leave the office, closing the laptop lid suspends the operating system, terminates local PTYs, and aborts in-flight agents.
* **The Solution**: The user selects `Target: Cloud Host` in the Launchpad (`⌘K`). The task is dispatched over Relay to an always-on Warren node. The developer packs up their laptop; the cloud daemon executes the task inside an isolated Git worktree; when the tests pass, a push notification is delivered to the user's iPhone.

### 2.2 Scenario 2: 24/7 Webhook Worker (Autonomous Issue Triage & PRs)
* **The Pain**: An open-source project or private repository receives a bug report via GitHub Issues. The maintainer is traveling or focused on high-priority work and cannot immediately pull code, reproduce, and patch.
* **The Solution**: The cloud daemon receives the GitHub Issue webhook, triggers an **RFC 0014 Pipeline** (`issue-to-release`), clones a worktree, generates reproduction tests, implements the fix, verifies that all tests pass, and publishes a draft PR with a descriptive comment:
  > *"I reproduced this issue and verified a fix with passing unit tests. Review draft PR #143."*
* The maintainer reviews the diff on mobile, taps `Approve`, and the bug is resolved without ever opening a laptop.

### 2.3 Scenario 3: Scheduled Cron Bots (Routine Maintenance & Aggregation)
* **The Pain**: Daily engineering maintenance—scanning dependency CVE advisories, summarizing community issue trends, performing repo health checks—is repetitive and constantly deferred.
* **The Solution**: A lightweight built-in cron scheduler triggers scheduled agent runs:
  - Daily at 08:30 AM: audits dependencies for known vulnerabilities, generates a concise 5-bullet executive summary, and notifies the team.
  - Weekly on Sunday night: runs end-to-end benchmark comparisons and detects latency regressions.

---

## 3. Architecture & Deployment Simplicity

To ensure zero adoption friction, the Cloud Daemon introduces **no external database dependencies, no mandatory Kubernetes clusters, and no complex ingress networking**.

### 3.1 The Relay Backbone (No Public Ingress Required)

The Cloud Daemon connects to the user's existing **Warren Relay (RFC 0009)** via an outbound TLS WebSocket connection (`/v1/host/connect`):
- The cloud server **does not require an open inbound public IP, domain name, or firewall hole**;
- Relay forwards client requests and incoming webhooks securely into the daemon;
- Clients (Desktop, Web, iOS) see the Cloud Daemon as a first-class remote host alongside local hosts:
  `● Cloud VPS (Ubuntu 24.04 · 4 vCPU · Connected via Relay)`.

### 3.2 Single-Command Setup

Deploying a 24/7 Warren Cloud Daemon is achieved in one command:

```bash
# Direct binary via installation script
curl -sSL https://get.warren.app/headless | sh -s -- \
  --relay wss://relay.example.com \
  --token <DAEMON_TOKEN> \
  --name "Hetzner-Cloud-01"

# Or via official Docker image
docker run -d --restart=always \
  --name warren-daemon \
  -v /var/warren:/root/.warren \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/abcdlsj/warren-headless:latest \
  --relay wss://relay.example.com \
  --token <DAEMON_TOKEN>
```

---

## 4. Declarative Configuration: Webhooks & Cron Schedules

The daemon loads configuration from `.warren/daemon.yaml` (or project root settings):

```yaml
version: 1
daemon:
  name: "production-worker-01"
  concurrency_limit: 2

# Webhook Ingestion Rules
webhooks:
  - id: github-issues
    source: github
    events: ["issues.opened", "issue_comment.created"]
    filters:
      label: "agent" # Only trigger if labeled 'agent' (or omit for all issues)
    action:
      pipeline: "issue-to-release" # Invokes RFC 0014 pipeline
      params:
        issue: "${event.issue.body}"
        issue_number: "${event.issue.number}"

# Scheduled Cron Bots
schedules:
  - id: morning-security-briefing
    cron: "30 8 * * *" # Daily at 08:30 AM
    action:
      pipeline: "security-audit"
      params:
        notify: "mobile" # Delivers Attention notification to Warren iOS
```

---

## 5. Mobile Attention & Delivery Loop

When an autonomous cloud run finishes or encounters a decision gate:
1. **Host Attention Signal**: The cloud daemon elevates an `Attention` event per RFC 0006/0010;
2. **Relay Push Forwarding**: Relay routes the signal to registered Apple Push Notification (APNs) endpoints;
3. **iOS Review Surface**:
   - Push Notification: `Pipeline #142 Ready for Review (All 18 tests passed)`;
   - One-tap opens the native Warren iOS Review sheet (RFC 0014 Touchpoint 4);
   - Actions available directly on mobile: `[Approve & Merge]`, `[Steer / Leave Note]`, `[Discard]`.

---

## 6. Acceptance Criteria (Baseline)

1. **Outbound Relay Enrollment**: The daemon successfully registers and authenticates with a Warren Relay instance, showing an active green status across connected Desktop and iOS clients without requiring open ingress ports.
2. **Off-the-Grid Continuity**: Tasks dispatched to the cloud daemon continue executing uninterrupted after the originating Desktop client disconnects.
3. **Webhook Ingestion**: Validated GitHub webhook events successfully launch an isolated RFC 0014 worktree pipeline on the cloud host.
4. **Cron Precision**: Configured cron schedules trigger on schedule and persist run history across daemon restarts.
5. **Mobile Notification & Delivery**: A completed cloud pipeline triggers a real-time push notification on iOS, allowing full diff inspection and one-tap PR creation.

---

## 7. Next Steps & Evolution

This baseline document serves as the foundational architectural anchor. Subsequent iterations will address:
- Secret management and sandboxed egress network policies;
- Multi-repository workspace cloning policies on cloud nodes;
- Automated PR commenting templates and bot identities.
