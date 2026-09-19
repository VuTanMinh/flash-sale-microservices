namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// Bound from the "Processing" appsettings.json section.
/// </summary>
public class ProcessingOptions
{
    /// <summary>
    /// How long the Process Worker pretends downstream processing takes,
    /// per Proposal §3: "deterministic delay" -- a fixed value, not a random
    /// or normally-distributed one. That matters for the Week 13/14
    /// experiments: a deterministic service time means any variance measured
    /// in end-to-end latency comes from queueing, contention and the
    /// architecture itself, not from the simulator adding noise of its own.
    ///
    /// Configurable rather than hardcoded because it is effectively the
    /// downstream system's service time, and Week 13/14 may want to vary it
    /// to push the pipeline into backlog deliberately.
    /// </summary>
    public int DelayMilliseconds { get; set; } = 200;
}
