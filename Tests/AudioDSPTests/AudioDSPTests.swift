import AudioDSP
import CoreAudio
import Testing

@Suite("Audio DSP")
struct AudioDSPTests {
    @Test func gainMuteBoostAndSoftLimit() throws {
        let context = try #require(DBDGainContextCreate(0.5))
        defer { DBDGainContextDestroy(context) }

        let input: [Float32] = [1, -0.5, 0.25, -1]
        #expect(process(input, context: context) == [0.5, -0.25, 0.125, -0.5])

        DBDGainContextSetGain(context, 0)
        #expect(process(input, context: context) == [0, 0, 0, 0])

        DBDGainContextSetGain(context, 2)
        let boosted = process(input, context: context)
        #expect(abs(boosted[2] - 0.5) < 0.0001)
        #expect(boosted[0] > 0.95 && boosted[0] < 1)
        #expect(boosted[1] < -0.95 && boosted[1] > -1)
        #expect(boosted[3] < -0.95 && boosted[3] > -1)
    }

    private func process(_ input: [Float32], context: UnsafeMutableRawPointer) -> [Float32] {
        var inputSamples = input
        var outputSamples = Array(repeating: Float32(9), count: input.count)
        var timestamp = AudioTimeStamp()

        inputSamples.withUnsafeMutableBytes { inputBytes in
            outputSamples.withUnsafeMutableBytes { outputBytes in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(inputBytes.count),
                        mData: inputBytes.baseAddress
                    )
                )
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outputBytes.count),
                        mData: outputBytes.baseAddress
                    )
                )
                _ = DBDGainAudioIOProc(
                    0,
                    &timestamp,
                    &inputList,
                    &timestamp,
                    &outputList,
                    &timestamp,
                    context
                )
            }
        }
        return outputSamples
    }
}
