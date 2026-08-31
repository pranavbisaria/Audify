import Accelerate
import CoreAudio
import Foundation
import os

/// Per-tap state read by the audio render thread.
///
/// Deliberately a trivial, fixed-layout struct held in manually managed memory: the render
/// callback must never touch ARC, allocate, or take a blocking lock.
struct RTSlot {
    /// Index into the aggregate device's input `AudioBufferList`, or -1 when unmapped.
    var inputBufferIndex: Int32 = -1
    var inputChannels: Int32 = 2
    /// Linear gain the UI wants (already folded with mute).
    var targetGain: Float = 1
    /// Gain actually applied, ramped towards `targetGain` to avoid zipper noise.
    var currentGain: Float = 1
    /// Decaying peak level, for the meters. Written by the render thread only.
    var peak: Float = 0
}

struct RTHeader {
    var slotCount: Int32 = 0
    /// One-pole coefficient for the gain ramp, derived from the sample rate.
    var rampCoefficient: Float = 0.002
    /// Non-zero when at least one slot is boosting above unity and needs soft clipping.
    var softClip: Int32 = 0
    var metersEnabled: Int32 = 0
    /// Incremented when the render thread had to skip a cycle because the structure was changing.
    var skippedCycles: Int32 = 0
    var peakDecay: Float = 0.85
    /// Render callbacks served. Distinguishes "graph is silent" from "graph never started".
    var renderCycles: Int32 = 0
    /// Input frames observed across all taps, for the same reason.
    var inputFrames: Int32 = 0
    /// Set once any tap delivers a non-silent sample.
    ///
    /// This is how Audify knows its audio-capture permission is really in force: when the
    /// permission is missing, Core Audio still creates the tap and still runs the render callback,
    /// it just hands over buffers of zeros. Nothing in the public API reports that, so observing
    /// it is the only reliable signal.
    var signalSeen: Int32 = 0
}

/// Owns the memory shared between the control thread and the audio render thread.
///
/// The split is deliberate:
/// * **Gain changes** (slider drags — frequent) are lock-free single-word stores.
/// * **Structural changes** (adding or removing a tap — rare) take an unfair lock that the render
///   thread only ever *tries*; if it can't get it, that one buffer is silence rather than a stall.
final class MixerRenderContext {
    static let capacity = 64

    let slots: UnsafeMutablePointer<RTSlot>
    let header: UnsafeMutablePointer<RTHeader>
    let lock: UnsafeMutablePointer<os_unfair_lock_s>

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: RTSlot(), count: Self.capacity)
        header = .allocate(capacity: 1)
        header.initialize(to: RTHeader())
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
        header.deinitialize(count: 1)
        header.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Lock-free gain update. A 4-byte aligned store is atomic on every platform we ship on, and
    /// the render thread tolerates reading a half-updated set of slots (worst case: one buffer
    /// ramps towards a stale target).
    func setGain(slot index: Int, gain: Float) {
        guard index >= 0, index < Self.capacity else { return }
        slots[index].targetGain = gain
    }

    func peak(slot index: Int) -> Float {
        guard index >= 0, index < Self.capacity else { return 0 }
        return slots[index].peak
    }

    /// Applies a structural change with the render thread locked out.
    func withStructuralLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
}

// MARK: - Render

/// Up to eight output channels are inspected; stereo content is placed in channels 0 and 1.
private let maxOutputChannels = 8

/// The audio render callback body, kept in one place so it stays easy to audit.
///
/// Real-time rules obeyed here: no allocation, no ARC traffic, no blocking locks, no logging,
/// no Swift runtime metadata access. Only pointer arithmetic and Accelerate primitives.
@inline(__always)
func audifyRender(
    slots: UnsafeMutablePointer<RTSlot>,
    header: UnsafeMutablePointer<RTHeader>,
    lock: UnsafeMutablePointer<os_unfair_lock_s>,
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>
) {
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    header.pointee.renderCycles &+= 1

    // Silence first: everything the tapped apps produce reaches the hardware only through us,
    // so any byte we do not write must be zero rather than whatever was in the buffer before.
    // Only the first two output channels carry the mix, so they are tracked as scalars: building
    // an array here would mean a heap allocation on the audio thread.
    var frames = 0
    var leftPointer: UnsafeMutablePointer<Float>?
    var rightPointer: UnsafeMutablePointer<Float>?
    var leftStride = vDSP_Stride(1)
    var rightStride = vDSP_Stride(1)
    var globalChannel = 0

    for buffer in outputBuffers {
        guard let data = buffer.mData else { continue }
        memset(data, 0, Int(buffer.mDataByteSize))

        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { continue }
        frames = max(frames, Int(buffer.mDataByteSize) / (4 * channels))

        let base = data.assumingMemoryBound(to: Float.self)
        for channel in 0..<channels {
            if globalChannel == 0 {
                leftPointer = base.advanced(by: channel)
                leftStride = vDSP_Stride(channels)
            } else if globalChannel == 1 {
                rightPointer = base.advanced(by: channel)
                rightStride = vDSP_Stride(channels)
            }
            globalChannel += 1
        }
        if globalChannel >= maxOutputChannels { break }
    }

    guard frames > 0, let left = leftPointer else { return }
    let right = rightPointer ?? left
    if rightPointer == nil { rightStride = leftStride }

    // The render thread never waits. If the control thread is mid-restructure we emit this one
    // buffer of silence (a few milliseconds) instead of risking a torn slot table or a priority
    // inversion on the audio thread.
    guard os_unfair_lock_trylock(lock) else {
        header.pointee.skippedCycles &+= 1
        return
    }
    defer { os_unfair_lock_unlock(lock) }

    let slotCount = Int(header.pointee.slotCount)
    guard slotCount > 0 else { return }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let inputCount = inputBuffers.count
    let ramp = header.pointee.rampCoefficient
    let metersEnabled = header.pointee.metersEnabled != 0
    let peakDecay = header.pointee.peakDecay

    for index in 0..<min(slotCount, MixerRenderContext.capacity) {
        let slot = slots + index
        let bufferIndex = Int(slot.pointee.inputBufferIndex)
        guard bufferIndex >= 0, bufferIndex < inputCount else { continue }

        let source = inputBuffers[bufferIndex]
        guard let sourceData = source.mData, source.mNumberChannels > 0 else { continue }

        let sourceChannels = Int(source.mNumberChannels)
        let sourceFrames = min(frames, Int(source.mDataByteSize) / (4 * sourceChannels))
        guard sourceFrames > 0 else { continue }
        header.pointee.inputFrames &+= Int32(sourceFrames)

        let sourceBase = sourceData.assumingMemoryBound(to: Float.self)
        let rightOffset = sourceChannels > 1 ? 1 : 0

        let target = slot.pointee.targetGain
        var current = slot.pointee.currentGain
        var peak: Float = 0

        if abs(target - current) < 1e-5 {
            // Steady state: hand the whole buffer to Accelerate. This is the path taken >99% of
            // the time, and it is where the CPU budget is actually won.
            slot.pointee.currentGain = target
            if target > 0 {
                var gain = target
                let sourceStride = vDSP_Stride(sourceChannels)
                vDSP_vsma(
                    sourceBase, sourceStride, &gain,
                    left, leftStride, left, leftStride, vDSP_Length(sourceFrames)
                )
                vDSP_vsma(
                    sourceBase.advanced(by: rightOffset), sourceStride, &gain,
                    right, rightStride, right, rightStride, vDSP_Length(sourceFrames)
                )
                // Computed unconditionally: one SIMD pass is far cheaper than the mixing
                // itself, and it doubles as the permission health check.
                vDSP_maxmgv(sourceBase, sourceStride, &peak, vDSP_Length(sourceFrames))
                peak *= gain
            }
        } else {
            // Ramping: one-pole glide towards the target so slider drags never click.
            for frame in 0..<sourceFrames {
                current += (target - current) * ramp
                let sourceIndex = frame * sourceChannels
                let sampleL = sourceBase[sourceIndex] * current
                let sampleR = sourceBase[sourceIndex + rightOffset] * current
                left[frame * Int(leftStride)] += sampleL
                right[frame * Int(rightStride)] += sampleR
                peak = max(peak, max(abs(sampleL), abs(sampleR)))
            }
            slot.pointee.currentGain = current
        }

        if peak > 1e-5 { header.pointee.signalSeen = 1 }
        if metersEnabled {
            let decayed = slot.pointee.peak * peakDecay
            slot.pointee.peak = max(decayed, peak)
        }
    }

    // Only pay for limiting when something is actually boosted past unity.
    if header.pointee.softClip != 0 {
        softClip(left, stride: Int(leftStride), frames: frames)
        if rightPointer != nil {
            softClip(right, stride: Int(rightStride), frames: frames)
        }
    }
}

/// Cubic soft clipper: transparent below ~0.67, saturates smoothly instead of wrapping.
///
/// Two multiplies per sample, no branches on the hot path, and no `tanh` call — the point of
/// allowing >100% gain is loudness, not distortion, so the curve stays gentle.
@inline(__always)
private func softClip(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int) {
    let threshold: Float = 2.0 / 3.0
    for frame in 0..<frames {
        let index = frame * stride
        let value = samples[index]
        if value > threshold {
            samples[index] = min(1.0, threshold + (value - threshold) / (1 + (value - threshold) * 3))
        } else if value < -threshold {
            samples[index] = max(-1.0, -threshold + (value + threshold) / (1 - (value + threshold) * 3))
        }
    }
}
