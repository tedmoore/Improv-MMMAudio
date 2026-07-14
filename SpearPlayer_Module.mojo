from std.sys import argv
from mmm_audio import *
from std.random import shuffle
from instrument.ControlsHandler_module import *
from instrument.Instrument import Modulable, ControlsRegistry
from std.pathlib import Path
from std.testing import assert_equal

struct ScrambleChannels(Movable,Copyable):
    var scramble_indices: List[Int64]
    var n_indices: Int

    def __init__(out self, nchannels: Int = 2):
        self.n_indices = nchannels
        self.scramble_indices = List[Int64](length=self.n_indices, fill=0)
        for i in range(self.n_indices):
            self.scramble_indices[i] = Int64(i)
        
        shuffle(self.scramble_indices)
    
    def next(mut self, input: List[Float64], mut output: List[Float64]):
        for i in range(self.n_indices):
            output[i] = input[self.scramble_indices[i]]

struct SpearChannelDelay(Copyable,Movable):
    var world: World
    var freqdelay: Delay[]
    var ampdelay: Delay[]
    var lfo: LFNoise[interp=Interp.linear]
    var max_delay_sec: Float64

    def __init__(out self, world: World, max_delay_sec: Float64):
        self.world = world
        self.max_delay_sec = max_delay_sec
        self.freqdelay = Delay(world, self.max_delay_sec)
        self.ampdelay = Delay(world, self.max_delay_sec)
        self.lfo = LFNoise[interp=Interp.linear](world)

    def next(mut self, freq: Float64, amp: Float64, amt: Float64) -> Tuple[Float64, Float64]:
        lfo_val = (self.lfo.next(0.1) + 1.0) * 0.5
        delay_time = lfo_val * self.max_delay_sec * amt
        delayed_freq = self.freqdelay.next(freq, delay_time)
        delayed_amp = self.ampdelay.next(amp, delay_time)
        return (delayed_freq, delayed_amp)

struct SpearFrames(Copyable,Movable):
    var num_frames: Int
    var num_channels: Int
    var data: List[Float64]

    def __init__(out self, num_frames: Int = 0, num_channels: Int = 0):
        self.num_frames = num_frames
        self.num_channels = num_channels
        self.data = List[Float64](length=self.num_frames * self.num_channels * 2, fill=0.0)

    # def resize(mut self, num_frames: Int, num_channels: Int):
    #     self.num_frames = num_frames
    #     self.num_channels = num_channels
    #     self.data.resize(new_size=num_frames * num_channels * 2, value=0.0)

    def set(mut self, frame: Int, channel: Int, freq: Float64, amp: Float64):
        i = ((frame * self.num_channels) + channel) * 2
        self.data[i] = freq
        self.data[i + 1] = amp

    def get(self, frame: Int, channel: Int) -> Tuple[Float64, Float64]:
        i = ((frame * self.num_channels) + channel) * 2
        return (self.data[i], self.data[i + 1])

    @staticmethod
    def write_u32_le(mut out: List[UInt8], value: Int):
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))

    @staticmethod
    def write_u64_le(mut out: List[UInt8], value: Int):
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 32) & 0xFF))
        out.append(UInt8((value >> 40) & 0xFF))
        out.append(UInt8((value >> 48) & 0xFF))
        out.append(UInt8((value >> 56) & 0xFF))

    @staticmethod
    def read_u32_le(data: List[UInt8], offset: Int) -> Int:
        return Int(data[offset]) + (Int(data[offset + 1]) << 8) + (Int(data[offset + 2]) << 16) + (Int(data[offset + 3]) << 24)

    @staticmethod
    def read_u64_le(data: List[UInt8], offset: Int) -> Int:
        return (
            Int(data[offset])
            + (Int(data[offset + 1]) << 8)
            + (Int(data[offset + 2]) << 16)
            + (Int(data[offset + 3]) << 24)
            + (Int(data[offset + 4]) << 32)
            + (Int(data[offset + 5]) << 40)
            + (Int(data[offset + 6]) << 48)
            + (Int(data[offset + 7]) << 56)
        )

    def save(self, path: String) raises:
        with open(path, "w") as f:
            # Header format:
            # 4 bytes magic "SPRF" + u32 version + u64 num_frames + u64 num_channels
            var header = List[UInt8]()
            header.append(UInt8(ord("S")))
            header.append(UInt8(ord("P")))
            header.append(UInt8(ord("R")))
            header.append(UInt8(ord("F")))
            SpearFrames.write_u32_le(header, 1)
            SpearFrames.write_u64_le(header, self.num_frames)
            SpearFrames.write_u64_le(header, self.num_channels)
            f.write_all(header)

            # Write-time is not critical; encode payload in little-endian Float64 bytes.
            var payload = List[UInt8]()
            payload.resize(new_size=len(self.data) * 8, value=0)
            var out_idx = 0
            for i in range(len(self.data)):
                var bits = bitcast[DType.uint64](self.data[i])
                payload[out_idx] = UInt8(bits & 0xFF)
                payload[out_idx + 1] = UInt8((bits >> 8) & 0xFF)
                payload[out_idx + 2] = UInt8((bits >> 16) & 0xFF)
                payload[out_idx + 3] = UInt8((bits >> 24) & 0xFF)
                payload[out_idx + 4] = UInt8((bits >> 32) & 0xFF)
                payload[out_idx + 5] = UInt8((bits >> 40) & 0xFF)
                payload[out_idx + 6] = UInt8((bits >> 48) & 0xFF)
                payload[out_idx + 7] = UInt8((bits >> 56) & 0xFF)
                out_idx += 8
            f.write_all(payload)

    @staticmethod
    def load(path: String) raises -> Self:
        with open(path, "r") as f:
            var header = f.read_bytes(24)
            if len(header) != 24:
                raise Error("SpearFrames.load: file too small")

            if header[0] != UInt8(ord("S")) or header[1] != UInt8(ord("P")) or header[2] != UInt8(ord("R")) or header[3] != UInt8(ord("F")):
                raise Error("SpearFrames.load: invalid magic")

            var version = SpearFrames.read_u32_le(header, 4)
            if version != 1:
                raise Error("SpearFrames.load: unsupported version")

            var num_frames = SpearFrames.read_u64_le(header, 8)
            var num_channels = SpearFrames.read_u64_le(header, 16)

            var out = SpearFrames(num_frames=num_frames, num_channels=num_channels)

            # Fast path: read payload directly into preallocated Float64 storage.
            var payload_span = Span[origin=MutAnyOrigin](ptr=out.data.unsafe_ptr(), length=len(out.data))
            var bytes_read = f.read(payload_span)
            var expected_bytes = len(out.data) * 8
            if bytes_read != expected_bytes:
                raise Error("SpearFrames.load: truncated payload")

            return out^

    @staticmethod
    def from_txt(txtpath: String, outputpath: Optional[String] = None) raises:
        with open(txtpath, 'r') as f:
            filecontents = f.read()
            lines_strings = filecontents.splitlines()

        lines = List[String]()
        nframes = 0

        for i,l in enumerate(lines_strings):
            line = l.split(' ')
            # line 2 is partials count, but that's total so it's not actually useful
            if i == 3:
                nframes = Int(line[1])
            elif i > 4:
                lines.append(String(l))
        
        # determine the max number of channels in a frame + max new appearing channels
        max_channels_in_a_frame = 0
        max_appearing_channels = 0

        previous_sine_indexes = Set[Int]()

        for l in lines:
            partsa = l.split(' ')
            n_channels = Int(partsa[1])
            max_channels_in_a_frame = max(max_channels_in_a_frame, n_channels)
            current_sine_indexes = Set[Int]()
            for i in range(n_channels):
                sine_index = Int(partsa[2 + (i * 3)])
                current_sine_indexes.add(sine_index)
            new_appearing_channels = current_sine_indexes - previous_sine_indexes
            max_appearing_channels = max(max_appearing_channels, len(new_appearing_channels))
            previous_sine_indexes = current_sine_indexes^
        
        needed_channels = max_channels_in_a_frame + max_appearing_channels
        out = SpearFrames(num_frames=nframes, num_channels=needed_channels)

        current_sines = List[Int](length=needed_channels, fill=-1)

        for frame_idx, l in enumerate(lines):
            parts = l.split(' ')
            n_channels = Int(parts[1])

            current_sines_dict = Dict[Int,Tuple[Float64,Float64]]()

            for i in range(n_channels):
                sine_index = Int(parts[2 + (i * 3)])
                freq = Float64(parts[3 + (i * 3)])
                amp = Float64(parts[4 + (i * 3)])

                current_sines_dict[sine_index] = (freq, amp)
            
            next_current_sines = List[Int](length=needed_channels, fill=-1)

            # any sines that are in current_sines, let's just extend
            for cs in current_sines_dict.items():
                if cs.key in current_sines:
                    idx = current_sines.index(cs.key)
                    (freq, amp) = cs.value
                    out.set(frame_idx, idx, freq, amp)
                    next_current_sines[idx] = cs.key

            # remove those from dict
            for i in next_current_sines:
                if i != -1:
                    _ = current_sines_dict.pop(i)

            # end any dead channels
            for i in range(len(current_sines)):
                if current_sines[i] != -1 and current_sines[i] not in next_current_sines:
                    f = out.get(frame_idx - 1, i)[0]
                    out.set(frame_idx, i, f, 0.0)
                    next_current_sines[i] = -2

            # add any new channels
            for cs in current_sines_dict.items():
                for i in range(len(next_current_sines)):
                    if next_current_sines[i] == -1:
                        (freq, _) = cs.value
                        out.set(frame_idx, i, freq, 0.0)
                        next_current_sines[i] = cs.key

            current_sines = next_current_sines^

        if outputpath:
            out.save(outputpath.value())

            # test = SpearFrames.load(outputpath.value())

            # assert_equal(test.num_frames, out.num_frames)
            # assert_equal(test.num_channels, out.num_channels)
            # for i in range(out.num_frames):
            #     for j in range(out.num_channels):
            #         (f1, a1) = out.get(i, j)
            #         (f2, a2) = test.get(i, j)
            #         assert_equal(f1, f2)
            #         assert_equal(a1, a2)

struct SpearPlayer(Modulable):
    var world: World
    var frames: SpearFrames
    var playhead: Float64
    var oscs: List[Osc[]]
    var scrambler: ScrambleChannels
    var rate: Float64Control
    var freqmul: LagFloat64Control
    # var tune_options_midi: List[Float64]
    # var tune_amt: Float64Control
    # var tuned_freqs: List[Float64]
    var channel_delays: List[SpearChannelDelay]
    var lfoamt: LagFloat64Control

    var sigs: List[Float64]
    var scrambled_out: List[Float64]
    var splayedout: MFloat[2]

    def get_namespace(self) -> String:
        return "spearplayer"

    def __init__(out self, world: World, spearframes_path: Optional[String] = None):

        if spearframes_path:
            try:
                self.frames = SpearFrames.load(spearframes_path.value())
            except e:
                abort(t"Failed to load Spear frames from {spearframes_path}: {e}")
        else:
            self.frames = SpearFrames()

        self.world = world
        self.oscs = List[Osc[]](length=self.frames.num_channels, fill=Osc[](world))
        self.playhead = 0.0
        self.rate = Float64Control(1, 0.01, 2, 4)
        self.freqmul = LagFloat64Control(self.world, 1.0, 0.01, 0.25, 4, 2)
        self.scrambler = ScrambleChannels(self.frames.num_channels)
        # self.tune_options_midi = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79, 81, 83, 84]
        # self.tune_amt = Float64Control(0.0, 0.0, 1.0)
        # self.tuned_freqs = List[Float64](length=self.frames.num_channels, fill=0.0)
        self.channel_delays = List[SpearChannelDelay](length=self.frames.num_channels, fill=SpearChannelDelay(world, 5.0))
        self.lfoamt = LagFloat64Control(self.world, 0.0, 0.01, 0.0, 1.0, 4)
        self.sigs = List[Float64](length=self.frames.num_channels, fill=0.0)
        self.scrambled_out = List[Float64](length=self.frames.num_channels, fill=0.0)
        self.splayedout = MFloat[2](0.0, 0.0)
    
    def getInterpolatedParams(self, frame_float: Float64, channel: Int) -> Tuple[Float64, Float64]:
        frame_int = Int(frame_float)
        frame_frac = frame_float - Float64(frame_int)
        next_frame = (frame_int + 1) % self.frames.num_frames
        (fa, aa) = self.frames.get(frame_int, channel)
        (fb, ab) = self.frames.get(next_frame, channel)
        f = linear_interp(fa, fb, frame_frac)
        a = linear_interp(aa, ab, frame_frac)
        return (f, a)

    # def tune_freq(self, freq: Float64, amt: Float64) -> Float64:
    #     inputmidi = cpsmidi(freq)
    #     winner = self.tune_options_midi[0]
    #     closest_distance = abs(inputmidi - winner)
    #     prev_dist = Float64.MAX
    #     for o in self.tune_options_midi:
    #         dist = abs(inputmidi - o)
    #         if dist < closest_distance:
    #             closest_distance = dist
    #             winner = o
    #         if dist > prev_dist:
    #             break
    #         prev_dist = dist
    #     out = linear_interp(inputmidi, winner, amt)
    #     out = midicps(out)
    #     out = sanitize(out)
    #     return out

    def next(mut self, cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:

        freqmul = self.freqmul.next()
        lfoamt = self.lfoamt.next()

        for i in range(len(self.oscs)):
            (f, a) = self.getInterpolatedParams(self.playhead, i)
            (f, a) = self.channel_delays[i].next(f, a, lfoamt)
            self.sigs[i] = self.oscs[i].next(f * freqmul) * a # * amp_comp_a(f * freqmul)
            
        # TODO: scramble when creating the data file to avoid it here
        self.scrambler.next(self.sigs, self.scrambled_out)

        self.splayedout = splay(input=self.scrambled_out,world=self.world)

        self.playhead += (self.rate.v / self.world[].sample_rate) * 100.0
        if self.playhead >= Float64(self.frames.num_frames):
            self.playhead = 0.0

        return self.splayedout

# def compute_midi_tuning_options(pitch_classes: List[Float64]) -> List[Float64]:
#     oct = 1.0
#     tom = List[Float64]()
#     go_on = True
#     while go_on:
#         for degree in pitch_classes:
#             m: Float64 = degree + (12.0 * oct)
#             if midicps(m) < 20000.0: # 20,000 Hz upper limit
#                 tom.append(m)
#             else:
#                 go_on = False
#                 break
#         oct += 1.0
#     return tom^

def main() raises:
    args = argv()
    inpath = args[1]
    outpath: Optional[String]

    if len(args) > 2:
        outpath = String(args[2])
    else:
        outpath = None

    if not Path(inpath).exists():
        raise Error(t"File does not exist: {inpath}")

    SpearFrames.from_txt(inpath, outpath)