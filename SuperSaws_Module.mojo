from mmm_audio import *
from instrument.ControlsHandler_module import *
from instrument.Instrument import Modulable, ControlsRegistry

struct SuperSawsVoice[n_oscs: Int = 8](PolyVoiceT):
    var world: World
    var env: Env
    var oscs: List[Osc[]]
    var pan_positions: List[Float64]
    var base_freq: Float64
    var freq_ratios: List[Float64]
    var trigger: Trig
    var phases: List[Float64]

    def __init__(out self, world: World):
        self.world = world
        self.env = Env(world)
        self.env.params.values = [0,1,1,0]
        self.env.params.times = [3,7,3]
        self.env.params.curves = [4, 1, -6]
        self.oscs = List[Osc[]](length=Self.n_oscs, fill=Osc(world))
        self.pan_positions = List[Float64](length=Self.n_oscs, fill=0.0)
        self.phases = List[Float64](length=Self.n_oscs, fill=0.0)
        self.freq_ratios = List[Float64](length=Self.n_oscs, fill=1.0)
        self.base_freq = 440.0
        self.trigger = Trig()
        
        for i, ii in enumerate([1,7,5,3,4,2,6,0]):
            self.pan_positions[i] = (Float64(ii) / (Float64(Self.n_oscs) - 1.0)) * 2.0 - 1.0
        
        for i, ii in enumerate([0,6,3,1,7,5,2,4]):
            self.phases[i] = Float64(ii) / (Float64(Self.n_oscs) - 1.0)

        

    # update *all* the values for this voice, this will be
    # called before trig so that the new values in place
    def update_values(mut self, values: List[Float64]):
        # [0] base freq, [1] freq dev (in semitones), [2] phase dev (0-1), [3] att, [4] sus dur, [5] rel

        self.base_freq = values[0]
        for i in range(Self.n_oscs):
            st = linlin(Float64(i), 0.0, Float64(Self.n_oscs) - 1.0, -values[1], values[1])
            self.freq_ratios[i] = 2.0 ** (st / 12.0)
        for i in range(Self.n_oscs):
            self.phases[i] = values[2] * (Float64(i) / Float64(Self.n_oscs))
        self.env.params.times[0] = values[3]
        self.env.params.times[1] = values[4]
        self.env.params.times[2] = values[5]

    # start this voice
    def trig(mut self):
        self.trigger.trig()

    def next(mut self, input: MFloat[2] = 0.0) -> MFloat[2]:

        env_out = self.env.next(self.trigger.next())

        if env_out <= 0.0:
            return 0.0

        out = MFloat[2](0.0)
        
        for i in range(Self.n_oscs):
            osc_out = self.oscs[i].next[osc_type=OscType.saw](freq=self.base_freq * self.freq_ratios[i], phase_offset=self.phases[i])
            out += pan2(osc_out, self.pan_positions[i])

        return out * env_out

    def is_active(self) -> Bool:
        return self.env.is_active

struct SuperSaws(Modulable):
    var world: World
    comptime nvoices = 16
    var poly: PolyT[SuperSawsVoice[], Self.nvoices, True]
    var ch: ControlsHandler
    var voice_keys: List[String]
    var received_values: List[Float64]
    var passing_values: List[Float64]

    var freq_dev: Float64Control
    var phase_dev: Float64Control
    var att: Float64Control
    var sus_dur: Float64Control
    var rel: Float64Control

    var prefilter_gain: Float64Control

    # var wavefolder: BuchlaWavefolder[2]
    # var wavefolder_drive: Float64Control
    # var wavefolder_offset: Float64Control

    var lpf: SVF[2]
    var ffreq: Float64Control 
    var q: Float64Control
    # var dctrap: DCTrap[2]
    var dist_gain: Float64Control

    # var ds: Downsampler[2]


    def get_namespace(self) -> String:
        return "SuperSaws"

    def __init__(out self, world: World):
        self.world = world
        # self.ds = Downsampler[2](self.world)

        self.poly = PolyT[SuperSawsVoice[], Self.nvoices, True](self.world, "SuperSaws_poly")
        self.ch = ControlsHandler(self.world, "SuperSaws")

        self.freq_dev = Float64Control(0.0, 0.0, 2.0)
        self.phase_dev = Float64Control(0.0, 0.0, 1.0)
        self.att = Float64Control(3, 0.1, 10.0)
        self.sus_dur = Float64Control(3.0, 0.0, 10.0)
        self.rel = Float64Control(7.0, 0.1, 10.0)
        self.prefilter_gain = Float64Control(-6.0, -20.0, 0.0)
        self.dist_gain = Float64Control(1.0, 1.0, 10.0, 2)

        self.passing_values = List[Float64](length=6, fill=0.0)
        self.passing_values[1] = self.freq_dev.v
        self.passing_values[2] = self.phase_dev.v
        self.passing_values[3] = self.att.v
        self.passing_values[4] = self.sus_dur.v
        self.passing_values[5] = self.rel.v
        self.received_values = List[Float64](length=2, fill=0.0)
        self.voice_keys = List[String]()
        for i in range(Self.nvoices):
            self.voice_keys.append("SuperSaws." + String(i))

        self.lpf = SVF[2](self.world)
        self.ffreq = Float64Control(2000.0, 20.0, 20000.0, 5)
        self.q = Float64Control(0.5, 0.1, 10.0, 2)

        # self.wavefolder = BuchlaWavefolder[2](self.world)
        # self.wavefolder_drive = Float64Control(1.0, 1.0, 2.0)
        # self.wavefolder_offset = Float64Control(0.0, -1.0, 1.0)
        # self.dctrap = DCTrap[2](self.world)
    
    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:

        for key in self.voice_keys:
            if self.ch.notify_update(key, self.received_values):
                print(t"SuperSaws::next: Received new values for {key}: {self.received_values}")
                self.passing_values[0] = midicps(self.received_values[0])
                self.passing_values[1] = self.freq_dev.v
                self.passing_values[2] = self.phase_dev.v
                self.passing_values[3] = self.att.v
                self.passing_values[4] = self.sus_dur.v
                self.passing_values[5] = self.rel.v
                self.poly.values_trig(self.passing_values)
        
        output = self.poly.next()
        # output = self.wavefolder.next(output + self.wavefolder_offset.v, self.wavefolder_drive.v)
        # output = self.dctrap.next(output)
        output = self.lpf.lpf(output * dbamp(self.prefilter_gain.v), self.ffreq.v, self.q.v)
        output = tanh(output * self.dist_gain.v)

        return output

struct SuperSaws_Module(Movable, Copyable):
    var world: World
    var synth: SuperSaws
    var cr: ControlsRegistry

    def __init__(out self, world: World):
        self.world = world
        self.synth = SuperSaws(self.world)
        self.cr = ControlsRegistry(self.world)

    def next(mut self, input: MFloat[2] = 0.0) -> MFloat[2]:
        return self.synth.next(input=input, cr=self.cr)