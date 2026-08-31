require "../../spec_helper"

# Helper: `count` frames of signed 16-bit mono silence, which is all
# these examples need - they are about the queue, not about the sound.
private def pcm_frames(count : Int32) : Bytes
  Bytes.new(count * 2, 0_u8)
end

private def with_stream(spec = Tryst::SDL::AudioSpec.new(format: Tryst::SDL::AudioFormat::S16LE,
                          channels: 1, freq: 44_100), &)
  stream = Tryst::SDL::AudioStream.new(spec)
  begin
    yield stream
  ensure
    stream.destroy
  end
end

describe Tryst::SDL::AudioStream do
  it "runs on a driver that makes no sound, so the suite stays quiet" do
    # The guarantee spec_helper sets up. If this ever reports a real
    # backend, running the specs has started playing audio out loud.
    Tryst::SDL::AudioStream.driver_name.should eq(ENV["SDL_AUDIO_DRIVER"])
  end

  it "finds a playback device" do
    Tryst::SDL::AudioStream.device_count.should be >= 1
    Tryst::SDL::AudioStream.available?.should be_true
  end

  it "keeps the format it was opened with" do
    spec = Tryst::SDL::AudioSpec.new(format: Tryst::SDL::AudioFormat::S16LE, channels: 1, freq: 22_050)
    with_stream(spec) do |stream|
      # The app's format, not the device's - SDL converts between them,
      # so what is queued is always interpreted as this.
      stream.spec.should eq(spec)
      stream.format.should eq(Tryst::SDL::AudioFormat::S16LE)
      stream.channels.should eq(1)
      stream.freq.should eq(22_050)
    end
  end

  it "starts paused, so queueing before playing cannot gap" do
    with_stream do |stream|
      stream.playing?.should be_false
    end
  end

  describe "#queue" do
    it "counts what is waiting, in bytes and in frames" do
      with_stream do |stream|
        stream.queued_bytes.should eq(0)
        stream.queue(pcm_frames(1000))

        # Still paused, so nothing has been consumed and the counts are
        # exactly what went in.
        stream.queued_bytes.should eq(2000)
        stream.queued_frames.should eq(1000)
      end
    end

    it "accumulates across calls" do
      with_stream do |stream|
        3.times { stream.queue(pcm_frames(100)) }
        stream.queued_frames.should eq(300)
      end
    end

    it "ignores an empty push rather than erroring" do
      with_stream do |stream|
        stream.queue(Bytes.new(0))
        stream.queued_bytes.should eq(0)
      end
    end

    it "counts frames by channel count, not by sample count" do
      stereo = Tryst::SDL::AudioSpec.new(format: Tryst::SDL::AudioFormat::S16LE, channels: 2)
      with_stream(stereo) do |stream|
        # 400 bytes is 200 samples, but only 100 frames in stereo. Frames
        # are what pacing cares about, which is why the distinction is
        # worth a test of its own.
        stream.queue(Bytes.new(400, 0_u8))
        stream.queued_bytes.should eq(400)
        stream.queued_frames.should eq(100)
      end
    end
  end

  describe "#gain" do
    it "starts at 1.0 and round-trips what it is set to" do
      with_stream do |stream|
        stream.gain.should eq(1.0_f32)

        stream.gain = 0.25
        stream.gain.should be_close(0.25, 0.0001)
      end
    end

    # The two ends a consumer actually reaches for: silence without
    # having to stop queueing, and amplification past the source's own
    # level. SDL allows both, so neither is clamped away here.
    it "accepts 0.0 for silence and a value above 1.0 to amplify" do
      with_stream do |stream|
        stream.gain = 0.0
        stream.gain.should eq(0.0_f32)

        stream.gain = 2.5
        stream.gain.should be_close(2.5, 0.0001)
      end
    end

    it "takes a Float64 as readily as a Float32" do
      with_stream do |stream|
        stream.gain = 0.5_f32
        stream.gain.should be_close(0.5, 0.0001)

        stream.gain = 0.75_f64
        stream.gain.should be_close(0.75, 0.0001)
      end
    end

    # SDL's own rejection names no value ("Parameter 'gain' is
    # invalid"), so a negative gain is caught here instead.
    it "refuses a negative gain, naming it" do
      with_stream do |stream|
        expect_raises(ArgumentError, /-0.5/) do
          stream.gain = -0.5
        end
        stream.gain.should eq(1.0_f32)
      end
    end

    it "refuses to answer once destroyed" do
      stream = Tryst::SDL::AudioStream.new
      stream.destroy
      expect_raises(Tryst::SDL::Error, /destroyed/) { stream.gain }
      expect_raises(Tryst::SDL::Error, /destroyed/) { stream.gain = 0.5 }
    end
  end

  describe "#clear" do
    it "throws away what has not played" do
      with_stream do |stream|
        stream.queue(pcm_frames(1000))
        stream.clear
        stream.queued_bytes.should eq(0)
      end
    end
  end

  describe "#resume / #pause" do
    it "starts and stops the device without discarding the queue" do
      with_stream do |stream|
        stream.queue(pcm_frames(44_100))

        stream.resume
        stream.playing?.should be_true

        stream.pause
        stream.playing?.should be_false
        # Paused keeps the data - the difference between #pause and
        # #clear, and what lets a synth stop and carry on.
        stream.queued_bytes.should be > 0
      end
    end
  end

  it "refuses to be used once destroyed" do
    stream = Tryst::SDL::AudioStream.new
    stream.destroy
    stream.destroy
    stream.destroyed?.should be_true
    expect_raises(Tryst::SDL::Error, /destroyed/) { stream.queued_bytes }
  end
end
