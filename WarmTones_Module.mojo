from mmm_audio import *
from instrument.ControlsHandler_module import *
from instrument.Instrument import Modulable, ControlsRegistry

struct WarmTonesVoice[n_oscs: Int = 8](PolyVoiceT):
    var world: World
    var env: Env
    var oscs: List[Osc[]]
    var pan_positions: List[Float64]
    var base_freq: Float64 = 440.0
    var freq_ratios: List[Float64]
    var trigger: Trig()
    var phases: List[Float64]

    def __init__(out self, world: World):
        self.world = world
        self.env = Env(world)
        self.env.values = [0,1,1,0]
        self.env.times = [3,7,3]
        self.oscs = OscBank[Self.n_oscs](world)
        self.pan_positions = List[Float64](length=Self.n_oscs, fill=0.0)
        self.phases = List[Float64](length=Self.n_oscs, fill=0.0)
        self.base_freq = 440.0
        for i in range(0, Self.n_oscs):
            self.pan_positions[i] = (i / (Self.n_oscs - 1)) * 2.0 - 1.0

    # update *all* the values for this voice, this will be
    # called before trig so that the new values in place
    def update_values(mut self, values: List[Float64]):
        # [0] base freq, [1] freq dev (in semitones), [2] phase dev (0-1), [3] att, [4] sus dur, [5] rel
        if len(values) > 0:
            self.base_freq = values[0]
        if len(values) > 1:
            for i in range(Self.n_oscs):
                st = linlin(i, 0, Self.n_oscs - 1, -values[1], values[1])
                self.freq_ratios[i] = 2.0 ** (st / 12.0)
        if len(values) > 2:
            for i in range(Self.n_oscs):
                self.phases[i] = values[2] * (i / Self.n_oscs)
        if len(values) > 3:
            self.env.times[0] = values[3]
        if len(values) > 4:
            self.env.times[1] = values[4]
        if len(values) > 5:
            self.env.times[2] = values[5]

    # start this voice
    def trig(mut self):
        self.trigger.trig()

    def next(mut self, input: MFloat[2] = 0.0) -> MFloat[2]:

        env_out = self.env.next(self.trigger.next())

        out = MFloat[2](0.0)

        if env_out <= 0.0:
            return out

        for i in range(Self.n_oscs):
            osc_out = self.oscs[i].next[osc_type=OscType.saw](freq=self.base_freq * self.freq_ratios[i], phase=self.phases[i])
            out += pan2(osc_out, self.pan_positions[i])

        return out * env_out

    def is_active(self) -> Bool:
        return self.env.is_active()

struct WarmTones(Modulable):
    var poly: PolyT[WarmTonesVoice, 8, False]
    var ch: ControlsHandler

    def get_namespace(self) -> String:
        return "warmtones"

    def __init__(out self, world: World):
        self.ch = ControlsHandler(world, self.get_namespace())
        self.poly = PolyT[WarmTonesVoice, 8, False](world, "warmtones_poly")
    
    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:

        if self.ch.notify_trig("warmtones.trig", cr):
            self.poly.values_trig(60.0)

        return self.poly.next(cr, input)

struct WarmTones_Module(Copyable, Movable):
    var wt: WarmTones
    var cr: ControlsRegistry

    def __init__(out self, world: World):
        self.cr = ControlsRegistry(world)
        self.wt = WarmTones(world)
    
    def next(mut self) -> MFloat[2]:
        return self.wt.next(self.cr)