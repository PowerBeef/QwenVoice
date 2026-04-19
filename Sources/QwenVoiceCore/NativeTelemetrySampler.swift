import Darwin
import Foundation

public struct TelemetrySample: Hashable, Codable, Sendable {
    public let tMS: Int
    public let residentMB: Double?
    public let physFootprintMB: Double?
    public let compressedMB: Double?
    public let headroomMB: Double?
    public let gpuAllocatedMB: Double?
    public let gpuRecommendedWorkingSetMB: Double?
    public let threads: Int
    public var stage: String?
    public var chunkIndex: Int?

    public init(
        tMS: Int,
        residentMB: Double?,
        physFootprintMB: Double?,
        compressedMB: Double?,
        headroomMB: Double?,
        gpuAllocatedMB: Double?,
        gpuRecommendedWorkingSetMB: Double?,
        threads: Int,
        stage: String? = nil,
        chunkIndex: Int? = nil
    ) {
        self.tMS = tMS
        self.residentMB = residentMB
        self.physFootprintMB = physFootprintMB
        self.compressedMB = compressedMB
        self.headroomMB = headroomMB
        self.gpuAllocatedMB = gpuAllocatedMB
        self.gpuRecommendedWorkingSetMB = gpuRecommendedWorkingSetMB
        self.threads = threads
        self.stage = stage
        self.chunkIndex = chunkIndex
    }
}

public struct TelemetrySummary: Codable, Sendable {
    public let residentStartMB: Double?
    public let residentEndMB: Double?
    public let residentPeakMB: Double?
    public let physFootprintPeakMB: Double?
    public let compressedPeakMB: Double?
    public let headroomStartMB: Double?
    public let headroomEndMB: Double?
    public let headroomMinMB: Double?
    public let gpuAllocatedPeakMB: Double?
    public let gpuRecommendedWorkingSetMB: Double?
    public let timeToPeakMS: Int?
    public let sampleCount: Int
    public let stageMarks: [NativeTelemetryStageMark]

    public init(
        residentStartMB: Double?,
        residentEndMB: Double?,
        residentPeakMB: Double?,
        physFootprintPeakMB: Double?,
        compressedPeakMB: Double?,
        headroomStartMB: Double?,
        headroomEndMB: Double?,
        headroomMinMB: Double?,
        gpuAllocatedPeakMB: Double?,
        gpuRecommendedWorkingSetMB: Double?,
        timeToPeakMS: Int?,
        sampleCount: Int,
        stageMarks: [NativeTelemetryStageMark]
    ) {
        self.residentStartMB = residentStartMB
        self.residentEndMB = residentEndMB
        self.residentPeakMB = residentPeakMB
        self.physFootprintPeakMB = physFootprintPeakMB
        self.compressedPeakMB = compressedPeakMB
        self.headroomStartMB = headroomStartMB
        self.headroomEndMB = headroomEndMB
        self.headroomMinMB = headroomMinMB
        self.gpuAllocatedPeakMB = gpuAllocatedPeakMB
        self.gpuRecommendedWorkingSetMB = gpuRecommendedWorkingSetMB
        self.timeToPeakMS = timeToPeakMS
        self.sampleCount = sampleCount
        self.stageMarks = stageMarks
    }
}

public actor NativeTelemetrySampler {
    private let startUptimeSeconds: TimeInterval
    private let sampleIntervalMS: Int
    private let buffer = TelemetrySampleBuffer()
    private var samplingTask: Task<Void, Never>?

    public init(
        startUptimeSeconds: TimeInterval,
        sampleIntervalMS: Int
    ) {
        self.startUptimeSeconds = startUptimeSeconds
        self.sampleIntervalMS = sampleIntervalMS
    }

    public func start() async {
        await buffer.append(sample: Self.captureSample(startUptimeSeconds: startUptimeSeconds))
        let intervalNanos = UInt64(max(sampleIntervalMS, 1)) * 1_000_000
        let buffer = self.buffer
        let startUptimeSeconds = self.startUptimeSeconds
        samplingTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                guard !Task.isCancelled else { break }
                await buffer.append(
                    sample: Self.captureSample(startUptimeSeconds: startUptimeSeconds)
                )
            }
        }
    }

    public func stop(stageMarks: [NativeTelemetryStageMark]) async -> (summary: TelemetrySummary, samples: [TelemetrySample]) {
        samplingTask?.cancel()
        _ = await samplingTask?.value
        await buffer.append(sample: Self.captureSample(startUptimeSeconds: startUptimeSeconds))
        let rawSamples = await buffer.snapshot()
        let samples = Self.decorate(samples: rawSamples, stageMarks: stageMarks)
        let summary = Self.summarize(samples: samples, stageMarks: stageMarks)
        return (summary, samples)
    }

    private static func decorate(
        samples: [TelemetrySample],
        stageMarks: [NativeTelemetryStageMark]
    ) -> [TelemetrySample] {
        let sortedMarks = stageMarks.sorted { lhs, rhs in
            if lhs.tMS == rhs.tMS {
                return lhs.stage < rhs.stage
            }
            return lhs.tMS < rhs.tMS
        }

        var nextMarkIndex = 0
        var currentStage: String?
        var currentChunkIndex: Int?
        return samples.map { sample in
            var sample = sample
            while nextMarkIndex < sortedMarks.count, sortedMarks[nextMarkIndex].tMS <= sample.tMS {
                let mark = sortedMarks[nextMarkIndex]
                currentStage = mark.stage
                currentChunkIndex = mark.metadata["chunk_index"].flatMap(Int.init)
                nextMarkIndex += 1
            }
            sample.stage = currentStage
            sample.chunkIndex = currentChunkIndex
            return sample
        }
    }

    private static func summarize(
        samples: [TelemetrySample],
        stageMarks: [NativeTelemetryStageMark]
    ) -> TelemetrySummary {
        let residentStartMB = samples.first?.residentMB
        let residentEndMB = samples.last?.residentMB
        let residentPeakSample = samples.max { lhs, rhs in
            (lhs.residentMB ?? 0) < (rhs.residentMB ?? 0)
        }
        let physFootprintPeakMB = samples.compactMap(\.physFootprintMB).max()
        let compressedPeakMB = samples.compactMap(\.compressedMB).max()
        let headroomStartMB = samples.first?.headroomMB
        let headroomEndMB = samples.last?.headroomMB
        let headroomMinMB = samples.compactMap(\.headroomMB).min()
        let gpuAllocatedPeakMB = samples.compactMap(\.gpuAllocatedMB).max()
        let gpuRecommendedWorkingSetMB = samples.compactMap(\.gpuRecommendedWorkingSetMB).max()

        return TelemetrySummary(
            residentStartMB: residentStartMB,
            residentEndMB: residentEndMB,
            residentPeakMB: residentPeakSample?.residentMB,
            physFootprintPeakMB: physFootprintPeakMB,
            compressedPeakMB: compressedPeakMB,
            headroomStartMB: headroomStartMB,
            headroomEndMB: headroomEndMB,
            headroomMinMB: headroomMinMB,
            gpuAllocatedPeakMB: gpuAllocatedPeakMB,
            gpuRecommendedWorkingSetMB: gpuRecommendedWorkingSetMB,
            timeToPeakMS: residentPeakSample?.tMS,
            sampleCount: samples.count,
            stageMarks: stageMarks
        )
    }

    private static func captureSample(startUptimeSeconds: TimeInterval) -> TelemetrySample {
        let tMS = Int((ProcessInfo.processInfo.systemUptime - startUptimeSeconds) * 1_000)
        let snapshot = IOSMemorySnapshot.capture()
        return TelemetrySample(
            tMS: tMS,
            residentMB: snapshot.residentMB,
            physFootprintMB: snapshot.physFootprintMB,
            compressedMB: snapshot.compressedMB,
            headroomMB: snapshot.availableHeadroomMB,
            gpuAllocatedMB: snapshot.gpuAllocatedMB,
            gpuRecommendedWorkingSetMB: snapshot.gpuRecommendedWorkingSetMB,
            threads: threadCount()
        )
    }

    private static func threadCount() -> Int {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        defer {
            if let threadList {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(UInt(bitPattern: threadList)),
                    vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return Int(threadCount)
    }
}

private actor TelemetrySampleBuffer {
    private var samples: [TelemetrySample] = []

    func append(sample: TelemetrySample) {
        samples.append(sample)
    }

    func snapshot() -> [TelemetrySample] {
        samples
    }
}
