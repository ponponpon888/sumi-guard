# Managed process identity security boundary

`PostExecutionEvidence` is untrusted input.  Its fields, including
`process_handle_obtained`, PID, executable path, and start time, are useful
diagnostics but cannot by themselves establish process identity.

Only the built-in production adapter can promote evidence to
`PROCESS_CONFIRMED`.  It constructs `Diagnostics.Process` itself, starts the
process, obtains a non-invalid native `Process.Handle`, then captures PID and
the UTC start time from that same live `Process` instance before waiting for
exit. `ProcessObserver`, `ProcessAdapterOverride`, `ProcessFactoryOverride`,
serialized evidence, and caller-supplied evidence are test/diagnostic seams:
they are returned for diagnostics but fail closed as
`PROCESS_EVIDENCE_UNTRUSTED` and are never promoted by the runner.

The object-identity attestation is deliberately an in-process routing control,
not a hostile-code security boundary. Although the registration helper is not
exported, code running in the same PowerShell process can invoke it through
the module scope (`Get-Module` and `& $module { ... }`). Such code already
shares process authority and can forge an attestation. SUMI GUARD therefore
does not claim that this mechanism prevents forgery by same-process code or
provides a cryptographic/durable proof of process identity. A boundary against
that threat needs OS isolation, a separate trusted process, or a durable
OS-supported attestation mechanism outside this contract.

The required time format is the invariant round-trip UTC form
`yyyy-MM-ddTHH:mm:ss.fffffffZ`.  Missing, malformed, offset-bearing, or
otherwise unparsable values fail closed as `PROCESS_IDENTITY_EVIDENCE_MISSING`.

The handle is used only while the `Process` object is live to obtain the
identity snapshot. `Process.Dispose()` releases managed/native resources; it
does not preserve a usable handle and is not exit evidence. The snapshot is
captured before waiting for exit, and SUMI GUARD does not retain or reuse the
handle after `Dispose()`, nor does it perform a post-exit PID lookup. It
therefore does not claim complete resistance to PID reuse after process exit.
A caller that requires an independent post-exit identity guarantee must use
an OS-supported durable process identity mechanism outside this evidence
contract.
