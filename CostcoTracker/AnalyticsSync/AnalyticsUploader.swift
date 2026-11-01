import Foundation

// MARK: - Upload engine
//
// start run → PUT batches 0…n-1 → complete, against the Analytics sync protocol.
// - Every batch body is the exact persisted byte sequence, so resends are
//   identical and the server replays them instead of applying them twice.
// - Transient failures (offline, 429, 5xx) are retried with backoff; if they
//   persist, the plan stays on disk and the run resumes later from the
//   server's list of received batches.
// - Rejections (bad data, conflicts) abort the run on the server and drop the
//   plan; nothing is retried blindly.
// - A revoked token stops immediately without aborting (the server would refuse).

nonisolated struct AnalyticsUploadProgress: Equatable, Sendable {
    var batchesSent: Int
    var batchCount: Int
}

nonisolated enum AnalyticsUploadOutcome: Equatable, Sendable {
    /// The run completed. `status` is "completed" or "needs_review" (the server
    /// held back removals for the owner to confirm on the website).
    case completed(status: String, pendingRemovals: Int)
}

nonisolated enum AnalyticsUploadFailure: Error, Equatable {
    /// Temporary problem; the plan is kept and the run will resume.
    case transient(AnalyticsAPIError)
    /// The server rejected the data or the run; the run was aborted and the plan dropped.
    case rejected(AnalyticsAPIError)
    /// The device token is no longer valid.
    case unauthenticated
}

struct AnalyticsUploader {
    var client: AnalyticsAPIClient
    var store: AnalyticsUploadStateStore
    /// Delays between attempts for one request (count = number of retries).
    var retryDelays: [Double] = [1, 3, 8]
    var sleep: (Double) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Sends (or resumes) `plan`. The plan is persisted before the first request.
    func upload(
        _ plan: AnalyticsUploadPlan,
        progress: (AnalyticsUploadProgress) -> Void = { _ in }
    ) async throws -> AnalyticsUploadOutcome {
        try? store.savePlan(plan)

        // Start is idempotent for the same runId, so it is also the resume entry point.
        let started: AnalyticsRunInfo
        do {
            started = try await withRetry {
                try await client.startRun(
                    runId: plan.runId,
                    mode: plan.mode,
                    exportedAt: plan.exportedAt,
                    requestId: plan.requestId
                )
            }
        } catch let error as AnalyticsAPIError {
            throw await fail(plan, error)
        }

        switch started.status {
        case "completed", "needs_review":
            store.clearPlan()
            return .completed(status: started.status, pendingRemovals: started.pendingRemovals.map { $0.receipts + $0.returns + $0.priceAdjustments } ?? 0)
        case "open":
            break
        default:
            // aborted/abandoned server-side: this plan can never finish.
            store.clearPlan()
            throw AnalyticsUploadFailure.rejected(.server(status: 409, code: "run_not_open", message: "The previous upload expired before it finished."))
        }

        var received = Set<Int>()
        if started.batchCount ?? 0 > 0 {
            if let status = try? await withRetry({ try await client.runStatus(runId: plan.runId) }) {
                received = Set(status.receivedSeqs)
            }
        }

        do {
            try await sendBatches(plan, skipping: received, progress: progress)
            let completed = try await complete(plan, progress: progress)
            store.clearPlan()
            return completed
        } catch let error as AnalyticsAPIError {
            throw await fail(plan, error)
        }
    }

    private func sendBatches(
        _ plan: AnalyticsUploadPlan,
        skipping received: Set<Int>,
        progress: (AnalyticsUploadProgress) -> Void
    ) async throws {
        var sent = received.count
        progress(AnalyticsUploadProgress(batchesSent: sent, batchCount: plan.batches.count))
        for (seq, body) in plan.batches.enumerated() where !received.contains(seq) {
            try await withRetry { try await client.putBatch(runId: plan.runId, seq: seq, body: body) }
            sent += 1
            progress(AnalyticsUploadProgress(batchesSent: sent, batchCount: plan.batches.count))
        }
    }

    private func complete(
        _ plan: AnalyticsUploadPlan,
        progress: (AnalyticsUploadProgress) -> Void
    ) async throws -> AnalyticsUploadOutcome {
        let run: AnalyticsRunInfo
        do {
            run = try await withRetry {
                try await client.completeRun(runId: plan.runId, batchCount: plan.batches.count, manifest: plan.manifest)
            }
        } catch let error as AnalyticsAPIError where error.code == "missing_batches" {
            // The server is missing some batches (e.g. a lost response). Resend exactly those, once.
            guard case .server(_, _, _, let missing, _) = error, !missing.isEmpty,
                  missing.allSatisfy({ plan.batches.indices.contains($0) })
            else { throw error }
            for seq in missing {
                try await withRetry { try await client.putBatch(runId: plan.runId, seq: seq, body: plan.batches[seq]) }
            }
            run = try await withRetry {
                try await client.completeRun(runId: plan.runId, batchCount: plan.batches.count, manifest: plan.manifest)
            }
        }
        let pending = run.pendingRemovals.map { $0.receipts + $0.returns + $0.priceAdjustments } ?? 0
        return .completed(status: run.status, pendingRemovals: pending)
    }

    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as AnalyticsAPIError where error.isTransient && attempt < retryDelays.count {
                await sleep(retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Classifies a failure, aborting the run when it can never succeed.
    private func fail(_ plan: AnalyticsUploadPlan, _ error: AnalyticsAPIError) async -> AnalyticsUploadFailure {
        if error.isUnauthenticated {
            return .unauthenticated
        }
        if error.isTransient {
            return .transient(error)
        }
        if error.code != "run_not_open" {
            try? await client.abortRun(runId: plan.runId)
        }
        store.clearPlan()
        return .rejected(error)
    }
}
