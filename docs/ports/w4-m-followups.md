# Wave 4 agent desk and Stop follow-ups

## Agent desk

An ambiguous schedule control failure keeps the optimistic switch values
visible and disables Pause and the routine switches until a host schedule
read succeeds. The existing automatic read retry still runs once on HTTP
429. If reconciliation cannot confirm the schedule, Refresh uses the
vendored `desktop.common.refresh` label and starts a schedule read with
the same busy retry. Closing the desk cancels its outstanding reads,
including a reconciliation retry. [Mobile client issue #85](https://github.com/atum-platform/atum-mobile-client/issues/85)

`AgentDeskBellTests` covers a Pause that reached the host even though its
response failed, two subsequent busy reads, and recovery through Refresh.
The reopen regression counts read starts after the closed desk's original
one-second retry deadline.
