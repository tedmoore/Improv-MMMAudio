from mmm_audio import *
from instrument.ControlsHandler_module import *
from instrument.Instrument import Modulable, ControlsRegistry

struct WarmTonesVoice[n_oscs: Int = 8](PolyVoiceT):
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
        self.oscs = List[Osc[]](length=Self.n_oscs, fill=Osc(world))
        self.pan_positions = List[Float64](length=Self.n_oscs, fill=0.0)
        self.phases = List[Float64](length=Self.n_oscs, fill=0.0)
        self.freq_ratios = List[Float64](length=Self.n_oscs, fill=1.0)
        self.base_freq = 440.0
        self.trigger = Trig()
        for i in range(0, Self.n_oscs):
            self.pan_positions[i] = (Float64(i) / (Float64(Self.n_oscs) - 1.0)) * 2.0 - 1.0

    # update *all* the values for this voice, this will be
    # called before trig so that the new values in place
    def update_values(mut self, values: List[Float64]):
        # [0] base freq, [1] freq dev (in semitones), [2] phase dev (0-1), [3] att, [4] sus dur, [5] rel
        if len(values) > 0:
            self.base_freq = values[0]
        if len(values) > 1:
            for i in range(Self.n_oscs):
                st = linlin(Float64(i), 0.0, Float64(Self.n_oscs) - 1.0, -values[1], values[1])
                self.freq_ratios[i] = 2.0 ** (st / 12.0)
        if len(values) > 2:
            for i in range(Self.n_oscs):
                self.phases[i] = values[2] * (Float64(i) / Float64(Self.n_oscs))
        if len(values) > 3:
            self.env.params.times[0] = values[3]
        if len(values) > 4:
            self.env.params.times[1] = values[4]
        if len(values) > 5:
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

struct WarmTones(Modulable):
    var poly: PolyT[WarmTonesVoice[], 8, False]
    var ch: ControlsHandler

    var freq_dev: Float64Control
    var phase_dev: Float64Control
    var att: Float64Control
    var sus: Float64Control
    var rel: Float64Control
    var base_midi: Float64

    var values: List[Float64]

    def get_namespace(self) -> String:
        return "warmtones"

    def __init__(out self, world: World):
        self.poly = PolyT[WarmTonesVoice[], 8, False](world, "warmtones_poly")
        self.ch = ControlsHandler(world, "warmtones")

        self.freq_dev = Float64Control(0.0, -0.5, 0.5)
        self.phase_dev = Float64Control(0.0, 0.0, 1.0)
        self.att = Float64Control(3.0, 0.1, 10.0)
        self.sus = Float64Control(3.0, 0.1, 10.0)
        self.rel = Float64Control(7.0, 0.1, 10.0)
        self.base_midi = 60.0

        self.values = [440.0, self.freq_dev.v, self.phase_dev.v, self.att.v, self.sus.v, self.rel.v]
    
    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:

        if self.ch.notify_update("warmtones.base_midi",self.base_midi):
            self.values[0] = midicps(self.base_midi)
            self.values[1] = self.freq_dev.v
            self.values[2] = self.phase_dev.v
            self.values[3] = self.att.v
            self.values[4] = self.sus.v
            self.values[5] = self.rel.v
            print("WarmTones values updated:", self.values)
            self.poly.values_trig(self.values)

        return self.poly.next()

struct WarmTones_Module(Copyable, Movable):
    var wt: WarmTones
    var cr: ControlsRegistry

    def __init__(out self, world: World):
        self.cr = ControlsRegistry(world)
        self.wt = WarmTones(world)
    
    def next(mut self) -> MFloat[2]:
        return self.wt.next(self.cr)