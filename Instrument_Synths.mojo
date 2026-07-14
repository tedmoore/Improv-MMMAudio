from mmm_audio import *
from instrument.ControlsHandler_module import *
from instrument.Instrument import *
from instrument.Poly import *
from emberjson import deserialize
from mojmelo.utils.Matrix import Matrix
from mojmelo.utils.KDTree import KDTreeResultVector, KDTree
from std.collections import Deque
from std.math import tanh
from std.random import random_float64, random_ui64

struct FBDelay(Modulable):
    comptime maxdelay: Float64 = 2.0
    var world: World
    var fbdel: FB_Delay[num_chans=2,interp=Interp.lagrange4]
    var deltime: LagFloat64Control
    var fb: Float64Control

    def __init__(out self, world: World):
        self.world = world
        self.fbdel = FB_Delay[num_chans=2,interp=Interp.lagrange4](self.world, max_delay_time = Self.maxdelay)
        self.deltime = LagFloat64Control(self.world, 0.5, 0.03, 0.001, Self.maxdelay)
        self.fb = Float64Control(-6, -130.0, 0.0, 8)

    def get_namespace(self) -> String:
        return "fbdelay"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:
        
        out = self.fbdel.next(input, self.deltime.next(), dbamp(self.fb.v))

        return out

struct Benjolin(Modulable):
    comptime times_oversampling: TimesOversampling = TimesOversampling.x2
    comptime interp: Interp = Interp.linear
    var world: World  
    var feedback: Float64
    var rungler: Float64
    var tri1: Osc[interp=Self.interp]
    var tri2: Osc[interp=Self.interp]
    var pulse1: Osc[interp=Self.interp]
    var pulse2: Osc[interp=Self.interp]
    var delays: List[Delay[1,Self.interp]]
    var latches: List[Latch[]]
    var filters: List[SVF[]]
    var filter_outputs: List[Float64]
    var sample_dur: Float64
    var sh: List[Float64]
    var dctraps: DCTrap[2]

    var freq1: Float64Control
    var freq2: Float64Control
    var scale: Float64Control
    var rungler1: Float64Control
    var rungler2: Float64Control
    var runglerFiltMul: Float64Control
    var loop: Float64Control
    var filterFreq: Float64Control
    var q: Float64Control
    var gain: Float64Control
    var filterType: Float64Control
    var outSignalL: Float64Control
    var outSignalR: Float64Control
    var ds: Downsampler[2,Self.times_oversampling]

    def get_namespace(self) -> String:
        return "benjolin"

    def __init__(out self, world: World):

        self.ds = Downsampler[2,Self.times_oversampling](world)

        self.world = world[].create_subworld(Self.times_oversampling)
        self.feedback = 0.0
        self.rungler = 0.0
        self.tri1 = Osc[interp=Self.interp](self.world)
        self.tri2 = Osc[interp=Self.interp](self.world)
        self.pulse1 = Osc[interp=Self.interp](self.world)
        self.pulse2 = Osc[interp=Self.interp](self.world)
        self.delays = List[Delay[1,Self.interp]](length=8,fill=Delay[1,Self.interp](self.world,max_delay_time=0.1))
        self.latches = List[Latch[]](length=8,fill=Latch())
        self.filters = List[SVF[]](length=9,fill=SVF(self.world))
        self.filter_outputs = List[Float64](length=9,fill=0.0)
        self.sample_dur = 1.0 / self.world[].sample_rate
        self.sh = List[Float64](length=9,fill=0.0)
        self.dctraps = DCTrap[2](self.world)

        self.freq1 = Float64Control(40, 20, 14000, 5)
        self.freq2 = Float64Control(5, 0.1, 14000, 5)
        self.scale = Float64Control(0.5, 0.0, 1.0)
        self.rungler1 = Float64Control(0.5, 0.0, 1.0)
        self.rungler2 = Float64Control(0.5, 0.0, 1.0)
        self.loop = Float64Control(0.5, 0.0, 1.0)
        self.filterFreq = Float64Control(4000, 20, 20000, 5)
        self.runglerFiltMul = Float64Control(1, 0.0, 1.0)
        self.q = Float64Control(0.82, 0.1, 8.0, 2)
        self.gain = Float64Control(0.5, 0.0, 2.0)
        self.filterType = Float64Control(0, 0, 8)
        self.outSignalL = Float64Control(0, 0, 6)
        self.outSignalR = Float64Control(0, 0, 6)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:

        for _ in range(Self.times_oversampling.times):
        
            tri1 = self.tri1.next[OscType.triangle]((self.rungler*self.rungler1.v)+self.freq1.v)
            tri2 = self.tri2.next[OscType.triangle]((self.rungler*self.rungler2.v)+self.freq2.v)
            pulse1 = self.pulse1.next[OscType.square]((self.rungler*self.rungler1.v)+self.freq1.v)
            pulse2 = self.pulse2.next[OscType.square]((self.rungler*self.rungler2.v)+self.freq2.v)

            pwm = 1.0 if (tri1 + tri2) > 0.0 else 0.0

            pulse1 = (self.feedback*self.loop.v) + (pulse1 * ((self.loop.v * -1) + 1))

            self.sh[0] = 1.0 if pulse1 > 0.5 else 0.0
            # pretty sure this makes no sense, but it matches the original code...:
            self.sh[0] = 1.0 if (1.0 > self.sh[0]) == (1.0 < self.sh[0]) else 0.0
            self.sh[0] = (self.sh[0] * -1) + 1

            self.sh[1] = self.delays[0].next(self.latches[0].next(self.sh[0],pulse2 > 0),self.sample_dur)
            self.sh[2] = self.delays[1].next(self.latches[1].next(self.sh[1],pulse2 > 0),self.sample_dur * 2)
            self.sh[3] = self.delays[2].next(self.latches[2].next(self.sh[2],pulse2 > 0),self.sample_dur * 3)
            self.sh[4] = self.delays[3].next(self.latches[3].next(self.sh[3],pulse2 > 0),self.sample_dur * 4)
            self.sh[5] = self.delays[4].next(self.latches[4].next(self.sh[4],pulse2 > 0),self.sample_dur * 5)
            self.sh[6] = self.delays[5].next(self.latches[5].next(self.sh[5],pulse2 > 0),self.sample_dur * 6)
            self.sh[7] = self.delays[6].next(self.latches[6].next(self.sh[6],pulse2 > 0),self.sample_dur * 7)
            self.sh[8] = self.delays[7].next(self.latches[7].next(self.sh[7],pulse2 > 0),self.sample_dur * 8)

            self.rungler = ((self.sh[0]/(2**8)))+(self.sh[1]/(2**7))+(self.sh[2]/(2**6))+(self.sh[3]/(2**5))+(self.sh[4]/(2**4))+(self.sh[5]/(2**3))+(self.sh[6]/(2**2))+(self.sh[7]/(2**1))

            self.feedback = self.rungler
            self.rungler = midicps(self.rungler * linlin(self.scale.v,0.0,1.0,0.0,127.0))

            self.filter_outputs[0] = self.filters[0].lpf(pwm * self.gain.v,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v)
            self.filter_outputs[1] = self.filters[1].hpf(pwm * self.gain.v,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v)
            self.filter_outputs[2] = self.filters[2].bpf(pwm * self.gain.v,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v)
            self.filter_outputs[3] = self.filters[3].lpf(pwm * self.gain.v,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v)
            self.filter_outputs[4] = self.filters[4].peak(pwm * self.gain.v,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v)
            self.filter_outputs[5] = self.filters[5].allpass(pwm * self.gain.v,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v)
            self.filter_outputs[6] = self.filters[6].bell(pwm,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v,ampdb(self.gain.v))
            self.filter_outputs[7] = self.filters[7].highshelf(pwm,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v,ampdb(self.gain.v))
            self.filter_outputs[8] = self.filters[8].lowshelf(pwm,(self.rungler*self.runglerFiltMul.v)+self.filterFreq.v,self.q.v,ampdb(self.gain.v))
            
            filter_output = select(self.filterType.v,self.filter_outputs) * dbamp(-12.0)
            filter_output = sanitize(filter_output)

            output = MFloat[2](
                select(self.outSignalL.v,tri1, pulse1, tri2, pulse2, pwm, self.sh[0], filter_output), 
                select(self.outSignalR.v,tri1, pulse1, tri2, pulse2, pwm, self.sh[0], filter_output)
            )

            output = self.dctraps.next(output)

            self.ds.add_sample(output)

        return self.ds.get_sample() * 0.4
        # return output * 0.4

struct Chorus(Modulable):
    comptime num_delays: Int = 12
    comptime maxdepth: Float64 = 0.2
    comptime maxpredelay: Float64 = 1
    var world: World
    var predelay: LagFloat64Control
    var speed: Float64Control
    var depth: LagFloat64Control
    var phasedif: Float64Control
    # var ch: ControlsHandler
    var delays: List[Delay[2,Interp.cubic]]
    var lfos: List[Osc[2]]
    var rands: List[MFloat[2]]

    def __init__(out self, world: World):
        self.world = world
        self.predelay = LagFloat64Control(self.world, 0.08, 0.03, 0, Self.maxpredelay)
        self.speed = Float64Control(0.05, 0.01, 0.1)
        self.depth = LagFloat64Control(self.world,0.1, 0.03,0.01, Self.maxdepth)
        self.phasedif = Float64Control(0.5, 0, 1)
        self.delays = List[Delay[2,Interp.cubic]]()
        self.lfos = List[Osc[2]]()
        self.rands = List[MFloat[2]]()

        for _ in range(Self.num_delays):
            self.delays.append(Delay[2,Interp.cubic](self.world,Self.maxdepth + Self.maxpredelay + 0.1))#extra 0.1 seconds for safety?
            self.lfos.append(Osc[2](self.world))
            self.rands.append(MFloat[2](random_float64(0.94,1.06),random_float64(0.94,1.06)))
    
    def get_namespace(self) -> String:
        return "chorus"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        out = MFloat[2]()
        depth = self.depth.next()
        predelay = self.predelay.next()

        for i in range(Self.num_delays):
            lfo = self.lfos[i].next(self.speed.v * self.rands[i],self.phasedif.v * Float64(i))
            lfo = linlin(lfo,-1,1,0,depth) + predelay
            out += self.delays[i].next(input,lfo)

        return out

struct MoogFF[num_chans: Int](Movable,Copyable):
    var world: World
    var s1: MFloat[Self.num_chans]
    var s2: MFloat[Self.num_chans]
    var s3: MFloat[Self.num_chans]
    var s4: MFloat[Self.num_chans]

    def __init__(out self, world: World):
        self.world = world
        self.s1 = MFloat[Self.num_chans](0.0)
        self.s2 = MFloat[Self.num_chans](0.0)
        self.s3 = MFloat[Self.num_chans](0.0)
        self.s4 = MFloat[Self.num_chans](0.0)

    def reset(mut self):
        self.s1 = MFloat[Self.num_chans](0.0)
        self.s2 = MFloat[Self.num_chans](0.0)
        self.s3 = MFloat[Self.num_chans](0.0)
        self.s4 = MFloat[Self.num_chans](0.0)

    def next(mut self, input: MFloat[Self.num_chans], freq: MFloat[Self.num_chans], gain: MFloat[Self.num_chans]) -> MFloat[Self.num_chans]:
        # Implementation of Dan Stowell's port of Fontana's Moog VCF algorithm
        
        # 1. Calculate tuning coefficients
        var two_pi_over_sr = 2.0 * pi / self.world[].sample_rate 
        var t0 = freq * two_pi_over_sr
        var t1 = exp(-t0)
        var p = MFloat[Self.num_chans](1.0) - t1
        
        # 2. Input stage with negative feedback scaled by gain (0 to 4)
        var in_sig = input - (gain * self.s4)
        
        # 3. 4-pole cascading lowpass filters
        self.s1 = self.s1 + p * (in_sig - self.s1)
        self.s2 = self.s2 + p * (self.s1 - self.s2)
        self.s3 = self.s3 + p * (self.s2 - self.s3)
        self.s4 = self.s4 + p * (self.s3 - self.s4)
        
        return self.s4

struct FilterGlitch(Modulable):
    var world: World
    var dust_rate: Float64Control
    var rand_freq_max: Float64Control
    var fb_gain_db: Float64Control
    var dust: Dust[2]
    var impulse: Impulse[2]
    # var moog: VAMoogLadder[2]
    var moog: MoogFF[2]
    var dctrap: DCTrap[2]
    var texprand: TExpRand[2]
    var feedback: MFloat[2]
    var delay_samps: IntControl
    var res: Float64Control

    var delay: Delay[2,Interp.none]
    var reset: Dust[]

    def __init__(out self, world: World):
        self.world = world
        self.dust_rate = Float64Control(0.1, 0.1, 60)
        self.rand_freq_max = Float64Control(100, 1, 20000, 5)
        self.fb_gain_db = Float64Control(0, 0, 20)
        self.dust = Dust[2](self.world)
        self.impulse = Impulse[2](self.world)
        # self.moog = VAMoogLadder[2](self.world)
        self.moog = MoogFF[2](self.world)
        self.dctrap = DCTrap[2](self.world)
        self.texprand = TExpRand[2]()
        self.feedback = MFloat[2](0.0)
        self.delay_samps = IntControl(64, 0, 512)
        self.res = Float64Control(3.8, 0.0, 4)

        self.delay = Delay[2,Interp.none](self.world, 0.1)
        self.reset = Dust[](self.world)
    
    def get_namespace(self) -> String:
        return "filterglitch"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        sig = self.dust.next(self.dust_rate.v)
        freq = self.texprand.next(1, self.rand_freq_max.v, sig.gt(0.0))
        # self.world[].print("freq: ", freq)
        sig = sig + self.delay.next(self.feedback, SIMD[DType.int,2](self.delay_samps.v))
        # sig = sig + self.feedback
        if self.reset.next_bool(3):
            self.moog.reset()
        sig = self.moog.next(sig, freq, self.res.v)
        sig = tanh(sig)
        self.feedback = MFloat[2](sig[1], sig[0]) * dbamp(self.fb_gain_db.v)
        sig = self.dctrap.next(sig)

        return sig

struct SIMDCircleBuffer[num_chans: Int = 1, interp: Interp = Interp.linear](Movable,Copyable):
    var world: World
    # the "end" of the buffer is always the last sample written,
    # so it always has the previous "size"
    var buffer: SIMDBuffer[Self.num_chans]
    var write_head: Int
    var num_frames: Int
    var num_frames_f64: Float64
    var previdx: Float64

    def __init__(out self, world: World, dur_secs: Float64):
        self.world = world
        self.num_frames = Int(dur_secs * self.world[].sample_rate)
        self.num_frames_f64 = Float64(self.num_frames)
        self.buffer = SIMDBuffer[Self.num_chans].zeros(self.num_frames * 2) # double the length for circular buffer
        self.write_head = 0
        self.previdx = 0.0

    def write_next(mut self, input: MFloat[Self.num_chans]) -> None:
        self.buffer.data[self.write_head] = input
        self.buffer.data[self.write_head + self.num_frames] = input
        self.write_head = (self.write_head + 1) % self.num_frames
    
    def read_phase(mut self, phs: Float64) -> MFloat[Self.num_chans]:
        # phs is 0 to 1, where 1 is the length of the buffer in samples
        index: Float64 = Float64(self.write_head) + (phs * self.num_frames_f64)
        out = SpanInterpolator.read[num_chans=Self.num_chans,interp=Self.interp](self.world,self.buffer.data, index, self.previdx)
        comptime if Self.interp == Interp.sinc:
            self.previdx = index
        return out

struct Stutter(Modulable):
    comptime bufferdur: Float64 = 2 # seconds
    var world: World
    # var ch: ControlsHandler
    var hold: BoolControl
    var hold_env: ASREnv
    var buffer: SIMDCircleBuffer[2]
    var phs: Phasor[1]
    var trand: TRand[]
    var loop_dur_secs: Float64
    var min_loop_dur_secs: Float64
    var max_loop_dur_secs: Float64
    var randomness_pow_warp: Float64Control

    def __init__(out self, world: World):
        self.world = world
        # self.ch = ControlsHandler(self.world,"stutter")
        self.hold = BoolControl(False)
        self.hold_env = ASREnv(self.world)
        self.buffer = SIMDCircleBuffer[2](self.world, Self.bufferdur)
        self.phs = Phasor[1](self.world)
        self.trand = TRand[]()
        self.min_loop_dur_secs = 0.03
        self.max_loop_dur_secs = Self.bufferdur
        self.loop_dur_secs = 0
        self.randomness_pow_warp = Float64Control(2.0, 0.1, 10.0, 2)


    def get_namespace(self) -> String:
        return "stutter"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        hold_env = self.hold_env.next(0.03,1.0,0.03,self.hold.v)

        self.loop_dur_secs = linlin(pow(self.trand.next(0,1,self.hold.v),self.randomness_pow_warp.v),0,1,self.min_loop_dur_secs,self.max_loop_dur_secs)

        if hold_env < neg130db:
            self.buffer.write_next(input * (1-hold_env))
            return input
        else:
            loopdur_phs: Float64 = self.loop_dur_secs / Self.bufferdur
            phs_offset = 1 - loopdur_phs
            phsfreq = 1.0 / self.loop_dur_secs
            phs = self.phs.next(phsfreq, trig=self.hold.v)
            out = self.buffer.read_phase(phs_offset + (phs * loopdur_phs))
            out = (out * hold_env) + (input * (1-hold_env))
            return out

struct Reverb(Modulable):
    var world: World
    var reverb: DattorroReverb[Interp.none]
    var predelay: Float64Control
    var decay: Float64Control
    var input_diffusion1: Float64Control
    var input_diffusion2: Float64Control
    var decay_diffusion1: Float64Control
    var decay_diffusion2: Float64Control
    var bandwidth: Float64Control
    var damping: Float64Control

    def __init__(out self, world: World):
        self.world = world
        self.reverb = DattorroReverb[Interp.none](self.world)
        self.decay = Float64Control(0.30,0.0,1.0)
        self.decay_diffusion1 = Float64Control(0.70,0.0,1.0)
        self.decay_diffusion2 = Float64Control(0.50,0.0,1.0)
        self.predelay = Float64Control(0.02,0.0,1.0)
        self.input_diffusion1 = Float64Control(0.750,0.0,1.0)
        self.input_diffusion2 = Float64Control(0.625,0.0,1.0)
        self.bandwidth = Float64Control(0.9995,0.0,1.0)
        self.damping = Float64Control(0.0005,0.0,1.0) #no damping = 0.0

    def get_namespace(self) -> String:
        return "reverb"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        self.reverb.set_all(
            self.predelay.v, 
            self.decay.v, 
            self.input_diffusion1.v, 
            self.input_diffusion2.v, 
            self.decay_diffusion1.v, 
            self.decay_diffusion2.v,
            self.bandwidth.v,
            self.damping.v
        )

        return self.reverb.next(input)

comptime two_pi = 2.0 * pi

struct SpecFreezeWindow[window_size: Int](FFTProcessable):
    comptime n_bins = (Self.window_size // 2) + 1
    var freeze_gate: Bool
    var stored_mags: List[MFloat[2]]

    def __init__(out self, world: World):
        self.freeze_gate = False
        self.stored_mags = [MFloat[2](0.0) for _ in range(Self.window_size)]

    def next_stereo_frame(mut self, mut mags: List[MFloat[2]], mut phases: List[MFloat[2]]) -> None:
        if not self.freeze_gate:
            self.stored_mags = mags.copy()
        else:
            mags = self.stored_mags.copy()
        for i in range(Self.n_bins):
            phases[i] = MFloat[2](random_float64(0, two_pi), random_float64(0, two_pi))
            
struct SpecFreeze(Modulable):
    comptime window_size = 2048
    comptime hop_size = Self.window_size // 4
    var world: World
    var fftp: FFTProcess[SpecFreezeWindow[Self.window_size],ifft=True,input_window_shape=WindowType.hann,output_window_shape=WindowType.hann]
    var freeze: BoolControl
    var asr: ASREnv

    def get_namespace(self) -> String:
        return "specfreeze"

    def __init__(out self, world: World):
        self.world = world
        self.freeze = BoolControl(False)
        self.fftp = FFTProcess[
                SpecFreezeWindow[Self.window_size],
                ifft=True,
                input_window_shape=WindowType.hann,
                output_window_shape=WindowType.hann
            ](self.world,process=SpecFreezeWindow[Self.window_size](self.world),window_size=Self.window_size,hop_size=Self.hop_size)
        self.asr = ASREnv(self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        self.fftp.get_process().freeze_gate = self.freeze.v
    
        env = self.asr.next(0.01, 1.0, 0.01, self.freeze.v, 1.0)
        freeze = self.fftp.next_stereo(input)
        return select(env, input, freeze)

struct AmpMod(Modulable):
    var world: World
    var freq: LagFloat64Control
    var osc: Osc[interp=Interp.linear]
    var bRingMod: BoolControl

    def __init__(out self, world: World):
        self.world = world
        self.freq = LagFloat64Control(self.world,8, 0.03, 0.5, 10000.0, 5)
        self.osc = Osc[interp=Interp.linear](self.world)
        self.bRingMod = BoolControl(False)

    def get_namespace(self) -> String:
        return "ampmod"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        mod = self.osc.next(self.freq.next())
        if not self.bRingMod.v: # not doing ring mod, means we *are* doing amp mod
            mod = linlin(mod,-1,1,0,1)
        return input * mod

struct SpectralSmearVoice(PolyVoiceT):
    var world: World
    var sines: List[Osc[interp=Interp.linear]]
    var freqs: List[Float64]
    var amps: List[Float64]
    var phases: List[Float64]
    var env: Env
    var trigger: Trig
    var pans: List[Float64]
    
    def __init__(out self, world: World):
        self.world = world
        self.sines = List[Osc[interp=Interp.linear]]()
        self.phases = List[Float64]()
        self.freqs = List[Float64]()
        self.amps = List[Float64]()
        self.env = Env(world)
        self.env.params.values = [0,1,1,0]
        self.env.params.times = [3,8,8]
        self.trigger = Trig()
        self.pans = List[Float64]()

    def update_values(mut self, values: List[Float64]):
        # first float is dur
        self.env.params.times[1] = values[0]
        # second float is max dev
        # [TODO]: max dev
        while len(self.sines) < (len(values)-2) // 2:
            self.sines.append(Osc[interp=Interp.linear](self.world))
            self.freqs.append(0.0)
            self.amps.append(0.0)
            self.pans.append(random_float64(-1,1))
            self.phases.append(random_float64(0, 2 * 3.14159))
        for i in range(2, len(values)-2, 2):
            idx = (i-2) // 2
            self.freqs[idx] = values[i]
            if self.freqs[idx] < self.world[].sample_rate / 2:
                self.amps[idx] = values[i+1]
            else:
                self.amps[idx] = 0.0
        
    def trig(mut self):
        self.trigger.trig()

    def next(mut self, input: MFloat[2]) -> MFloat[2]:
        out = MFloat[2](0.0)
        for i in range(len(self.sines)):
            out += pan2(self.sines[i].next(self.freqs[i], self.phases[i]) * self.amps[i], self.pans[i])
        out *= self.env.next(self.trigger.next())
        return out

    def is_active(self) -> Bool:
        return self.env.is_active

def amp_comp_a(freq: Float64) -> Float64:
    """Approximate A-weighting curve for frequency-dependent amplitude compensation.
    Based on SuperCollider's AmpCompA implementation, which is derived from [here](http://www.beis.de/Elektronik/AudioMeasure/WeightingFilters.html).
    """
    # [TODO] Write a test to compare with SuperCollider's implementation.
    comptime k =  3.5041384e16
    comptime c1 = 424.31867740601
    comptime c2 = 11589.093052022
    comptime c3 = 544440.67046057
    comptime c4 = 148698928.24309
    var r = freq ** 2
    var m1 = r ** 4
    var n1 = (c1 + r) ** 2
    var n2 = c2 + r
    var n3 = c3 + r
    var n4 = (c4 + r) ** 2
    var level = k * m1 / (n1 * n2 * n3 * n4)
    return sqrt(level)

struct SpectralSmear(Modulable):
    comptime n_sines: Int = 32
    comptime poly_n: Int = 10
    comptime window_size: Int = 4096
    comptime hop_size: Int = Self.window_size
    var world: World
    var ch: ControlsHandler
    var poly: PolyT[SpectralSmearVoice, Self.poly_n, steal=True]
    var fftp: FFTProcess[TopNFreqs,ifft=False,input_window_shape=WindowType.hann,output_window_shape=WindowType.rect]
    var floats_to_pass: List[Float64]
    var trig_freq_mul: Float64
    var dur: Float64Control
    var max_dev: Float64Control

    def __init__(out self, world: World):
        self.world = world
        self.poly = PolyT[SpectralSmearVoice, Self.poly_n, steal=True](world, "specsmear_poly")
        self.floats_to_pass = List[Float64](length=2 + (Self.n_sines * 2),fill=0.0)
        self.trig_freq_mul = 1.0
        self.dur = Float64Control(8,0.1,20,0.25)
        self.max_dev = Float64Control(0.5,0.0,12.0,0.25)
        self.ch = ControlsHandler(self.world, "specsmear")
        self.fftp = FFTProcess[
                TopNFreqs,
                ifft=False,
                input_window_shape=WindowType.hann,
                output_window_shape=WindowType.rect
            ](self.world,process=TopNFreqs(self.world[].sample_rate,Self.window_size,Self.n_sines,False,-70),window_size=Self.window_size,hop_size=Self.hop_size)

    def get_namespace(self) -> String:
        return "specsmear"

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        _ = self.fftp.next(input.reduce_add())

        if self.ch.notify_update("specsmear.trig_freq_mul", self.trig_freq_mul):

            self.floats_to_pass[0] = self.dur.v
            self.floats_to_pass[1] = self.max_dev.v

            for i, pair in enumerate(self.fftp.get_process().freq_amp_pairs):
                self.floats_to_pass[2 + (i * 2)] = pair[0] * self.trig_freq_mul
                self.floats_to_pass[3 + (i * 2)] = pair[1] * amp_comp_a(pair[0])

            self.poly.values_trig(self.floats_to_pass)
    
        out = self.poly.next()
    
        return out

struct SampleSpaceData(Movable,Copyable, Defaultable, Writable):
    var path: String
    var start_frame_num_frames: List[Tuple[Float64, Float64]] # floats in order to default to float math later
    var points: List[List[Float32]]

    def __init__(out self):
        self.path = ""
        self.start_frame_num_frames = List[Tuple[Float64, Float64]]()
        self.points = List[List[Float32]]()

struct SampleSpace(Modulable):
    var world: World
    var ch: ControlsHandler
    var phasor: Phasor[2]
    var posx: Float64Control
    var posy: Float64Control
    var rate: Float64Control
    var buf: Buffer
    var data: SampleSpaceData
    var kdtree: KDTree[sort_results=False] # only doing 1 anyway
    var results: KDTreeResultVector
    var inputxy: List[Float32]
    var start_frame_num_frames: InlineArray[MFloat[2],2] # float in order to default to float math later
    var xstring: String
    var ystring: String
    var namespace: String

    def __init__(out self, world: World, json_path: Optional[String] = None):
        self.world = world
        self.namespace = "samplespace"
        self.ch = ControlsHandler(self.world,self.namespace)
        self.phasor = Phasor[2](self.world)
        self.posx = Float64Control(0.5, 0.0, 1.0)
        self.posy = Float64Control(0.5, 0.0, 1.0)
        self.rate = Float64Control(1.0, 0.25, 4.0, 0.5)
        self.inputxy = List[Float32](length=2, fill=0.5)
        self.start_frame_num_frames = InlineArray[MFloat[2],2](fill=0.0)
        self.xstring = self.namespace + ".posx"
        self.ystring = self.namespace + ".posy"

        if json_path:
            try:
                with open(json_path.value(), "r") as f:
                    self.data = deserialize[SampleSpaceData](f.read())
                    self.buf = Buffer.load(self.data.path)
                    matrix = Matrix(len(self.data.points), len(self.data.points[0]))

                    for i in range(len(self.data.points)):
                        for j in range(len(self.data.points[i])):
                            matrix[i,j] = self.data.points[i][j]
                    
                    self.kdtree = KDTree[sort_results=False](matrix,build=True)
                    self.results = KDTreeResultVector()
                
            except e:
                abort("SampleSpace::init" + String(e))
        else:
            self.buf = Buffer.zeros(0)
            self.data = SampleSpaceData()
            try:
                self.kdtree = KDTree[sort_results=False](Matrix(0,0),build=False)
                self.results = KDTreeResultVector()
            except e:
                abort("SampleSpace::init" + String(e))
            
    def get_namespace(self) -> String:
        return self.namespace

    def update_nearest(mut self):
        try:
            self.kdtree.n_nearest(Span[origin=MutAnyOrigin](ptr=self.inputxy.unsafe_ptr(), length=len(self.inputxy)), 2, self.results)
            nearest_idx0 = self.results[0].idx
            nearest_idx1 = self.results[1].idx
            # start for 0
            self.start_frame_num_frames[0][0] = self.data.start_frame_num_frames[nearest_idx0][0]
            # start for 1
            self.start_frame_num_frames[0][1] = self.data.start_frame_num_frames[nearest_idx1][0]
            # num for 0
            self.start_frame_num_frames[1][0] = self.data.start_frame_num_frames[nearest_idx0][1]
            # num for 1
            self.start_frame_num_frames[1][1] = self.data.start_frame_num_frames[nearest_idx1][1]
        except e:
            print("SampleSpace::update_nearest " + String(e))

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        trig: Bool = False
        if self.ch.notify_update(self.xstring, self.posx.v):
            self.inputxy[0] = Float32(self.posx.v)
            trig = True
        if self.ch.notify_update(self.ystring, self.posy.v):
            self.inputxy[1] = Float32(self.posy.v)
            trig = True

        if trig:
            self.update_nearest()

        dur_sec: MFloat[2] = self.start_frame_num_frames[1] / self.buf.sample_rate
        phs: MFloat[2] = self.phasor.next(self.rate.v / dur_sec)
        f_idx: MFloat[2] = self.start_frame_num_frames[0] + (phs * self.start_frame_num_frames[1])

        out = MFloat[2](0.0)
        for i in range(2):
            out[i] = SpanInterpolator.read[1,Interp.cubic,False](self.world,self.buf.data[0],f_idx[i])

        return out

struct Squiz(Modulable):
    comptime update_dur: Float64 = 0.1 # seconds
    var world: World
    var buf: Buffer
    var write_head: Int
    # var ch: ControlsHandler
    var rate: Float64Control
    var n_zcs: IntControl
    var nf_over_2: Int

    var phasor: Phasor[2]
    var start_frames: MFloat[2]
    var num_frames: MFloat[2]
    var phasor_rates: MFloat[2]
    var zcs: Deque[Int]

    def get_namespace(self) -> String:
        return "squiz"
    
    def __init__(out self, world: World):
        self.world = world
        self.write_head = 0
        self.nf_over_2 = Int(self.world[].sample_rate * Self.update_dur)
        self.buf = Buffer.zeros(self.nf_over_2 * 2,2)

        self.rate = Float64Control(1, 1, 10.0, 0.25)
        self.n_zcs = IntControl(1, 1, 10)
        self.phasor = Phasor[2](self.world)
        self.start_frames = MFloat[2]()
        self.num_frames = MFloat[2]()
        self.phasor_rates = MFloat[2]()
        self.zcs = Deque[Int]()

    def is_zero_crossing(self, chan: Int, idx: Int) -> Bool:
        prev_idx = ((idx + self.buf.num_frames) - 1) % self.buf.num_frames
        return self.buf.data[chan][prev_idx] < 0 and self.buf.data[chan][idx] >= 0

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        for i in range(2):
            self.buf.data[i][self.write_head] = input[i]

        trig = self.is_zero_crossing(0,self.write_head)

        if trig:
            previdx = ((self.write_head + self.buf.num_frames) - 1) % self.buf.num_frames
            self.zcs.append(previdx)
            if len(self.zcs) >= (self.n_zcs.v + 1):
                endidx = len(self.zcs) - 1
                startidx = endidx - self.n_zcs.v
                self.start_frames = Float64(self.zcs[startidx])
                self.num_frames = Float64(self.zcs[endidx]) - self.start_frames
                self.phasor_rates = 1.0 / (self.num_frames / self.world[].sample_rate)
            
            while len(self.zcs) > self.n_zcs.v + 1:
                try:
                    _ = self.zcs.popleft()
                except e:
                    abort("Squiz::next "+String(e))

        out = MFloat[2](0.0)

        phs = self.phasor.next(self.phasor_rates * self.rate.v,trig=MBool[2](fill=trig))
        phs *= self.num_frames
        phs += self.start_frames

        for i in range(2):
            out[i] = SpanInterpolator.read[1,Interp.cubic,False](self.world,self.buf.data[i],phs[i])
    
        self.write_head = (self.write_head + 1) % self.buf.num_frames

        return out

struct MatrixMixer(Movable, Copyable):
    var n_inputs: Int
    var coeffs: List[List[Float64Control]]
    var output: List[Float64]

    def io_to_idx(self, i: Int, o: Int) -> Int:
        return o * self.n_inputs + i

    def __init__(out self, inputs: Int, outputs: Int):
        self.n_inputs = inputs
        self.coeffs = List[List[Float64Control]](length=outputs, fill=List[Float64Control](length=inputs, fill=Float64Control(0.0, -1000.0, 1000.0, 1.0, False)))
        self.output = List[Float64](length=outputs, fill=0.0)

    def next(mut self, input: List[Float64]):
        for o in range(len(self.output)):
            sum: Float64 = 0.0
            for i in range(self.n_inputs):
                sum += input[i] * self.coeffs[o][i].v
            self.output[o] = sum

struct Integrator(Movable, Copyable):
    var prev: Float64

    def __init__(out self):
        self.prev = 0.0
    
    def next(mut self, input: Float64, coeff: Float64) -> Float64:
        self.prev = input + (self.prev * coeff)
        return self.prev

struct FIN(Modulable):
    comptime times_oversampling: TimesOversampling = TimesOversampling.x2
    comptime n_integrators: Int = 8
    comptime hop_size: Int = 128
    comptime delaysamps = SIMD[DType.int,2](Self.hop_size)
    var world: World 
    var ds_world: World
    var snd: List[Float64]
    var impulse: Impulse[]
    var integrators: List[Integrator]
    var matrix_mixer: MatrixMixer
    var dctrap: List[DCTrap[]]
    var filters: List[SVF[]]
    var ffreqs: List[Float64Control]
    var qs: List[Float64Control]
    var gains: List[Float64Control]
    var randomize: TrigControl
    var initialized: Bool
    var ds: Downsampler[2,Self.times_oversampling]

    var mask_prob: Float64Control
    var onsets: SpectralFluxOnsets
    var mask_env: ASREnv
    var mask_bool: Bool
    var rbd: RisingBoolDetector[]

    var delay: Delay[2]

    def get_namespace(self) -> String:
        return "fin"
        
    def __init__(out self, world: World):

        self.ds = Downsampler[2,Self.times_oversampling](world)

        self.world = world
        self.ds_world = self.world[].create_subworld(Self.times_oversampling)

        self.impulse = Impulse(self.ds_world)
        self.snd = List[Float64](length=Self.n_integrators, fill=0.0)
        self.integrators = List[Integrator](length=Self.n_integrators, fill=Integrator())
        self.matrix_mixer = MatrixMixer(Self.n_integrators, Self.n_integrators)
        self.dctrap = List[DCTrap[]](length=Self.n_integrators, fill=DCTrap(self.ds_world))
        self.filters = List[SVF[]](length=Self.n_integrators, fill=SVF(self.ds_world))
        self.ffreqs = List[Float64Control](length=Self.n_integrators,fill=Float64Control(10.0, 10.0, 1000.0, 1.0, False))
        self.qs = List[Float64Control](length=Self.n_integrators,fill=Float64Control(0.707,0.1,10.0,1,False))
        self.gains = List[Float64Control](length=Self.n_integrators,fill=Float64Control(0.0,-12,12,1,False))
        self.randomize = TrigControl()
        self.initialized = False

        self.mask_prob = Float64Control(0.0, 0.0, 1.0)
        self.onsets = SpectralFluxOnsets(self.world,window_size=Self.hop_size * 2,hop_size=Self.hop_size,filter_size=5)
        self.onsets.min_slice_len = 0.05
        self.mask_env = ASREnv(self.world)
        self.mask_bool = False
        self.rbd = RisingBoolDetector[]()

        self.delay = Delay[2](self.ds_world, 0.1)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        if not self.initialized:
            cr.register("fin.onset_thresh", self.onsets.thresh)
            for o in range(Self.n_integrators):
                cr.register("fin.freq."+String(o), self.ffreqs[o])
                cr.register("fin.q."+String(o), self.qs[o])
                cr.register("fin.gain."+String(o), self.gains[o])
                for i in range(Self.n_integrators):
                    cr.register("fin.coeff."+String(self.matrix_mixer.io_to_idx(i, o)), self.matrix_mixer.coeffs[o][i])
            self.initialized = True

        if self.randomize.next():
            for o in range(Self.n_integrators):
                self.ffreqs[o].set_normalized_value(random_float64(0, 1.0))
                self.qs[o].set_normalized_value(random_float64(0, 1.0))
                self.gains[o].set_normalized_value(random_float64(0, 1.0))
                for i in range(Self.n_integrators):
                    self.matrix_mixer.coeffs[o][i].set_normalized_value(random_float64(0, 1.0))

        # self.world[].print("fin: "+String(self.ffreqs[0].v)+" "+String(self.qs[0].v)+" "+String(self.gains[0].v)+" "+String(self.matrix_mixer.coeffs[0][0].v))

        for _ in range(Self.times_oversampling.times):

            # self.world[].print("fin impulse freq: ",self.impulse_freq.v)
            imp = self.impulse.next(0.1)
            for i in range(Self.n_integrators):
                self.snd[i] = self.integrators[i].next(self.snd[i] + imp, 0.999)
                # self.snd[i] = self.integrators[i].next(self.feedback[i] + imp, 0.999)
            
            self.matrix_mixer.next(self.snd)
            for i in range(Self.n_integrators):
                self.snd[i] = self.matrix_mixer.output[i]
            
            self.snd[0] = self.filters[0].next[FilterType.lowpass](self.snd[0], self.ffreqs[0].v, self.qs[0].v,self.gains[0].v)
            self.snd[1] = self.filters[1].next[FilterType.bandpass](self.snd[1], self.ffreqs[1].v, self.qs[1].v,self.gains[1].v)
            self.snd[2] = self.filters[2].next[FilterType.highpass](self.snd[2], self.ffreqs[2].v, self.qs[2].v,self.gains[2].v)
            self.snd[3] = self.filters[3].next[FilterType.bell](self.snd[3], self.ffreqs[3].v, self.qs[3].v,self.gains[3].v)
            self.snd[4] = self.filters[4].next[FilterType.highshelf](self.snd[4], self.ffreqs[4].v, self.qs[4].v,self.gains[4].v)
            self.snd[5] = self.filters[5].next[FilterType.lowshelf](self.snd[5], self.ffreqs[5].v, self.qs[5].v,self.gains[5].v)
            self.snd[6] = self.filters[6].next[FilterType.notch](self.snd[6], self.ffreqs[6].v, self.qs[6].v,self.gains[6].v)
            self.snd[7] = self.filters[7].next[FilterType.peak](self.snd[7], self.ffreqs[7].v, self.qs[7].v,self.gains[7].v)

            for i in range(Self.n_integrators):
                # self.feedback[i] = self.delays[i].next[1](self.snd[i], self.deltime.v)
                self.snd[i] = sanitize(self.snd[i])
                self.snd[i] = self.dctrap[i].next(self.snd[i]) # TODO: try without
                self.snd[i] = tanh(self.snd[i]) # TODO: try without or with TanhAD or other distortions

            self.ds.add_sample(splay(self.snd,self.world))

        output = self.ds.get_sample()

        # self.world[].print("onset thresh:",self.onsets.thresh)

        if self.rbd.next(self.onsets.next(output.reduce_add())):
            self.mask_bool = random_float64(0.0,1.0) < self.mask_prob.v
            # print("fin mask_bool: ", self.mask_bool)

        # output = self.delay.next(output, Self.delaysamps)
            
        output *= self.mask_env.next(0.01, 1.0, 0.01, not self.mask_bool)
        # output *= Float64(not self.mask_bool)

        return output

struct LPFilter(Modulable):
    var world: World
    var cutoff: Float64Control
    var q: Float64Control
    var filter: SVF[2]

    def get_namespace(self) -> String:
        return "lpfilter"

    def __init__(out self, world: World):
        self.world = world
        self.cutoff = Float64Control(1000.0,20,20000,5)
        self.q = Float64Control(8.0,0.1,10.0)
        self.filter = SVF[2](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        return self.filter.lpf(input, self.cutoff.v, self.q.v)

struct Phasey(Modulable):
    comptime times_oversampling: TimesOversampling = TimesOversampling.x2
    comptime num_ops: Int = 3
    comptime drift_hz: Float64 = 0.1
    comptime drift_amt: Float64 = 0.001
    comptime num_drift_params: Int = Self.num_ops * 6
    comptime num_drift_params_next_pow2: Int = next_power_of_two(Self.num_drift_params)
    var world: World
    var carriers: List[Osc[2, Interp.quad]]
    var modulators: List[Osc[2, Interp.quad]]
    var drift: LFNoise[Self.num_drift_params_next_pow2, Interp.linear]
    var car0: Float64Control
    var mod0: Float64Control
    var index0: LagFloat64Control
    var car1: Float64Control
    var mod1: Float64Control
    var index1: LagFloat64Control
    var car2: Float64Control
    var mod2: Float64Control
    var index2: LagFloat64Control
    var car_min: List[Float64]
    var car_max: List[Float64]
    var mod_min: List[Float64]
    var mod_max: List[Float64]
    var os: Downsampler[2,Self.times_oversampling]
    var dctrap: DCTrap[2]

    def get_namespace(self) -> String:
        return "phasey"

    @always_inline
    def drifted(self, value: Float64, drift_l: Float64, drift_r: Float64) -> MFloat[2]:
        return MFloat[2](
            clip(value + drift_l, 0.0, 1.0),
            clip(value + drift_r, 0.0, 1.0)
        )

    def __init__(out self, world: World):
        self.world = world

        self.car0 = Float64Control(0.0, 0.0, 1.0)
        self.car1 = Float64Control(0.0, 0.0, 1.0)
        self.car2 = Float64Control(0.0, 0.0, 1.0)
        self.mod0 = Float64Control(0.0, 0.0, 1.0)
        self.mod1 = Float64Control(0.0, 0.0, 1.0)
        self.mod2 = Float64Control(0.0, 0.0, 1.0)
        self.car_min = List[Float64](capacity=Self.num_ops)
        self.car_max = List[Float64](capacity=Self.num_ops)
        self.mod_min = List[Float64](capacity=Self.num_ops)
        self.mod_max = List[Float64](capacity=Self.num_ops)

        self.drift = LFNoise[Self.num_drift_params_next_pow2, Interp.linear](self.world)

        self.os = Downsampler[2,Self.times_oversampling](self.world)

        osw = self.world[].create_subworld(self.times_oversampling)

        self.carriers = List[Osc[2, Interp.quad]](length=Self.num_ops,fill=Osc[2, Interp.quad](osw))
        self.modulators = List[Osc[2, Interp.quad]](length=Self.num_ops,fill=Osc[2, Interp.quad](osw))
        self.index0 = LagFloat64Control(osw, 0.0, 0.01, 0.0, 1.0)
        self.index1 = LagFloat64Control(osw, 0.0, 0.01, 0.0, 1.0)
        self.index2 = LagFloat64Control(osw, 0.0, 0.01, 0.0, 1.0)

        for _ in range(Self.num_ops):
            self.car_min.append(0.1)
            self.car_max.append(4000.0)
            self.mod_min.append(0.1)
            self.mod_max.append(2000.0)

        self.car_min[2] = 20.0

        self.dctrap = DCTrap[2](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:
        drifts = self.drift.next(Self.drift_hz) * Self.drift_amt

        for _ in range(Self.times_oversampling.times):
            car0 = self.drifted(self.car0.v, drifts[0], drifts[1])
            mod0 = self.drifted(self.mod0.v, drifts[2], drifts[3])
            index0 = self.drifted(self.index0.next(), drifts[4], drifts[5])
            car_freq0 = linexp(car0, 0.0, 1.0, self.car_min[0], self.car_max[0])
            mod_freq0 = linexp(mod0, 0.0, 1.0, self.mod_min[0], self.mod_max[0])
            mod_sig0 = self.modulators[0].next(mod_freq0, MFloat[2](0.0))
            op0 = self.carriers[0].next(car_freq0, linlin(mod_sig0,-1.0,1.0,0.0,1.0) * index0)

            car1 = self.drifted(self.car1.v, drifts[6], drifts[7])
            mod1 = self.drifted(self.mod1.v, drifts[8], drifts[9])
            index1 = self.drifted(self.index1.next(), drifts[10], drifts[11])
            car_freq1 = linexp(car1, 0.0, 1.0, self.car_min[1], self.car_max[1])
            mod_freq1 = linexp(mod1, 0.0, 1.0, self.mod_min[1], self.mod_max[1])
            mod_sig1 = self.modulators[1].next(mod_freq1, linlin(op0,-1.0,1.0,0.0,1.0))
            op1 = self.carriers[1].next(car_freq1, linlin(mod_sig1,-1.0,1.0,0.0,1.0) * index1)

            car2 = self.drifted(self.car2.v, drifts[12], drifts[13])
            mod2 = self.drifted(self.mod2.v, drifts[14], drifts[15])
            index2 = self.drifted(self.index2.next(), drifts[16], drifts[17])
            car_freq2 = linexp(car2, 0.0, 1.0, self.car_min[2], self.car_max[2])
            mod_freq2 = linexp(mod2, 0.0, 1.0, self.mod_min[2], self.mod_max[2])
            mod_sig2 = self.modulators[2].next(mod_freq2, linlin(op1,-1.0,1.0,0.0,1.0))
            op2 = self.carriers[2].next(car_freq2, linlin(mod_sig2,-1.0,1.0,0.0,1.0) * index2)
            self.os.add_sample(sanitize(op2))

        return self.dctrap.next(self.os.get_sample())

struct SampCollGrain(Movable, Copyable):
    var world: World
    var bufidx: Int
    var rate: Float64
    var start_frame: Int
    var num_frames: Int
    var player: Play
    var pan: Float64
    var trigger: Trig
    var env: Env

    def __init__(out self, world: World):
        self.world = world
        self.bufidx = 0
        self.player = Play(self.world)
        self.pan = random_float64(-1.0, 1.0)
        self.trigger = Trig()
        self.rate = 1.0
        self.start_frame = 0
        self.num_frames = 0

        self.env = Env(self.world)
        self.env.params.values = [0.0, 1, 1, 0]
        self.env.params.times = [0.03, 0.01, 0.03]

    def next(mut self, buf: SIMDBuffer[1]) -> MFloat[2]:

        trig = self.trigger.next()
        env = self.env.next(trig)

        if not self.env.is_active:
            return 0.0

        mono = self.player.next(
            buf=buf,
            rate=self.rate,
            loop=False,
            trig=trig,
            start_frame=self.start_frame,
            num_frames=self.num_frames)

        return pan2(mono * env, self.pan)

    def is_active(self) -> Bool:
        return self.env.is_active
    
    def values_trig(mut self, rate: Float64, bufidx: Int, start_frame: Int, num_frames: Int, buf: SIMDBuffer[1], pan: Float64):
        self.rate = rate
        self.bufidx = bufidx
        self.start_frame = start_frame
        self.num_frames = num_frames
        self.env.params.times[1] = buf.duration - 0.06
        self.pan = pan
        self.trigger.trig()

struct SampColl(Modulable):
    var world: World
    var bufs: List[SIMDBuffer[1]]
    var grains: List[SampCollGrain]
    var trig_rate: Float64Control
    var random_rate: BoolControl
    # var steal_voice: BoolControl
    var impulse: Impulse[]
    var checking_index: Int

    def __init__(out self, world: World):
        self.world = world
        paths = select_files("/Users/ted/Desktop/favs-mono",[".wav"])
        self.bufs = List[SIMDBuffer[1]](capacity=len(paths))
        for p in paths:
            # print("SampColl loading ",p)
            self.bufs.append(SIMDBuffer[1].load(p))
        self.grains = List[SampCollGrain](length=40,fill=SampCollGrain(self.world))

        self.trig_rate = Float64Control(1.0, 0.1, 20.0, 4)
        self.impulse = Impulse[](self.world)

        self.random_rate = BoolControl(False)
        # self.steal_voice = BoolControl(False)
        self.checking_index = 0

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        if self.impulse.next_bool(self.trig_rate.v):
            if self.random_rate.v:
                rate = exprand(0.5, 2.0)
            else:
                rate = 1.0
            bufidx = Int(random_ui64(0, UInt64(len(self.bufs)-1)))
            start_frame = 0
            num_frames = self.bufs[bufidx].num_frames
            pan = random_float64(-1.0, 1.0)
            # print("SampColl trig ",bufidx," rate ",rate," pan ",pan," num_frames ",num_frames)
            self.grains[self.checking_index].values_trig(rate, bufidx, start_frame, num_frames, self.bufs[bufidx], pan)
            self.checking_index = (self.checking_index + 1) % len(self.grains)
                    # break

        out = MFloat[2](0.0)
        for i in range(len(self.grains)):
            out += self.grains[i].next(self.bufs[self.grains[i].bufidx])

        return out

    def get_namespace(self) -> String:
        return "sampcoll"

struct ChromaChannel(Movable, Copyable):
    comptime num_partials: Int = 7
    var world: World
    var base_midi: Float64
    var partials: List[Osc[1,Interp.linear]]
    var pans: List[Float64]
    var partials_drift: List[LFNoise[1,Interp.linear]]
    var amps: List[Lag[]]

    def set_lag_times(mut self, lag_time: Float64):
        for ref a in self.amps:
            a.set_lag_time(lag_time)

    def __init__(out self, world: World, base_midi: Float64):
        self.world = world
        self.base_midi = base_midi
        self.partials = List[Osc[1,Interp.linear]](capacity=Self.num_partials)
        self.pans = List[Float64](capacity=Self.num_partials)
        self.partials_drift = List[LFNoise[1,Interp.linear]](capacity=Self.num_partials)
        self.amps = List[Lag[]](capacity=Self.num_partials)

        for i in range(Self.num_partials):
            self.partials.append(Osc[1,Interp.linear](world))
            # self.pans.append(random_float64(-1.0, 1.0))
            self.pans.append(Float64(((i % 2) * 2) - 1)) # alternate left/right
            self.partials_drift.append(LFNoise[1,Interp.linear](world))
            self.amps.append(Lag[](world, 0.1))

    def next_legacy(mut self, midi_offset: Float64, chan: Int) -> MFloat[2]:
        out: MFloat[2] = 0.0
        for i in range(Self.num_partials):
            freq = midicps(self.base_midi + midi_offset + (self.partials_drift[i].next(0.1) * 0.1)) * Float64(i)
            si = self.partials[i].next(freq)
            si /= Float64(i+1)
            si *= self.amps[i].next(1.0 - Float64(clip(abs(i-chan),0,1)))
            out += pan2(si,self.pans[i])
        return out

    def next(mut self, midi_offset: Float64, medal: Int) -> MFloat[2]:
        out: MFloat[2] = 0.0
        for i in range(Self.num_partials):
            freq = midicps(self.base_midi + midi_offset + (self.partials_drift[i].next(0.1) * 0.1)) * Float64(i+1)
            si = self.partials[i].next(freq)
            si /= Float64(i+1)
            si *= self.amps[i].next(1.0 - Float64(clip(abs(i-(medal//2)),0,1)))
            out += pan2(si,self.pans[i])
        return out
        
struct ChromaSusWindow[n_chroma: Int](FFTProcessable):
    comptime base_midis: List[Float64] = [24,25,26,27,28,29,30,31,32,33,34,35]
    comptime legacy_functionality: Bool = False
    var chroma: Chroma
    var ordinal: List[Int]
    var modified_ordinal: List[Int]
    var midi_offset: Float64
    var lag_chroma: Lags[Self.n_chroma]
    var audio_lag_chroma: Lags[Self.n_chroma]
    var channels: List[ChromaChannel]
    var mask_envs: List[ASREnv]
    var mask_bools: List[Bool]
    var medal_stand: List[Int]

    def __init__(out self, world: World, window_size: Int, hop_size: Int):

        comptime assert len(Self.base_midis) == Self.n_chroma, "base_midis length must match n_chroma"
        
        self.chroma = Chroma(world[].sample_rate,window_size,n_chroma=Self.n_chroma,norm=1.0)
        self.ordinal = List[Int](length=Self.n_chroma,fill=0)
        self.modified_ordinal = List[Int](length=Self.n_chroma,fill=0)
        self.medal_stand = List[Int](length=Self.n_chroma,fill=0)
        self.mask_bools = List[Bool](length=Self.n_chroma,fill=True)
        self.midi_offset = 0.0
        self.lag_chroma = Lags[Self.n_chroma](world[].sample_rate / Float64(hop_size),0.1)
        # self.lag_chroma = Lags[Self.n_chroma](world,0.1)
        self.audio_lag_chroma = Lags[Self.n_chroma](world,0.1)

        self.mask_envs = List[ASREnv](capacity=Self.n_chroma)
        self.channels = List[ChromaChannel](capacity=Self.n_chroma)
        comptime for i in range(Self.n_chroma):
            self.channels.append(ChromaChannel(world, materialize[Self.base_midis[i]]()))
            self.mask_envs.append(ASREnv(world))

    def set_lag_times(mut self, lag_time: Float64):
        self.lag_chroma.set_lag_time(lag_time)
        self.audio_lag_chroma.set_lag_time(lag_time)
        for ref c in self.channels:
            c.set_lag_times(lag_time)
    
    def next_frame(mut self, mags: List[Float64], phases: List[Float64]):
        self.chroma.from_mags(mags)

        self.lag_chroma.next(self.chroma.chroma)

        # for i in range(Self.n_chroma):
        #     print("lag chroma[",i,"] = ",self.lag_chroma[i])

        # argsort
        for i in range(Self.n_chroma):
            self.ordinal[i] = i
        def cmp_fn(a: Int, b: Int) capturing -> Bool:
            # larger values to the left
            return self.lag_chroma[a] > self.lag_chroma[b]
        sort[cmp_fn](self.ordinal)

        # the ordinal here is now such that ordinal[0] contains the index 
        # of the loudest chroma, ordinal[1] the second loudest, etc.
        # if ordinal[0] == 0, then C is the loudest chroma, 
        # if ordinal[0] == 1, then C# is the loudest chroma, etc.
        # print("loudest chroma: ",self.ordinal[0])

        comptime if Self.legacy_functionality:
            for i in range(1,self.n_chroma):
                self.modified_ordinal[i] = (self.ordinal[i] + 1) // 2
        else:
            for i in range(Self.n_chroma):
                self.medal_stand[self.ordinal[i]] = i

    def next(mut self, 
        midi_offset: Float64, 
        mask_C: Bool, 
        mask_Csh: Bool,
        mask_D: Bool, 
        mask_Dsh: Bool,
        mask_E: Bool, 
        mask_F: Bool, 
        mask_Fsh: Bool,
        mask_G: Bool, 
        mask_Gsh: Bool,
        mask_A: Bool, 
        mask_Ash: Bool,
        mask_B: Bool
        ) -> MFloat[2]:

        out: MFloat[2] = 0.0

        self.audio_lag_chroma.next(self.chroma.chroma)

        comptime if Self.legacy_functionality:
            for i in range(Self.n_chroma):
                ii: Int = self.modified_ordinal[i]
                sig = self.channels[i].next_legacy(midi_offset, chan=ii)
                menv = self.mask_envs[i].next(0.03,1,0.03,self.mask_bools[i])
                out += sig * menv * self.audio_lag_chroma[i]
        else:
            for i in range(Self.n_chroma):
                sig = self.channels[i].next(midi_offset, medal=self.medal_stand[i])
                menv = self.mask_envs[i].next(0.03,1,0.03,self.mask_bools[i])
                out += sig * menv * self.audio_lag_chroma[i]
        return out

struct ChromaSus(Modulable):
    comptime n_chroma: Int = 12
    comptime widowsize: Int = 2048
    comptime hopsize: Int = Self.widowsize
    var viscosity: Float64Control
    var midi_offset: Float64Control
    var chroma: FFTProcess[ChromaSusWindow[Self.n_chroma],ifft=False,input_window_shape=WindowType.hann]
    var viscositychanged: Changed[Float64]
    var midi_offset_changed: Changed[Float64]

    # it's like this because it makes autocreating the GUI easier
    var mask_C: BoolControl
    var mask_Csh: BoolControl
    var mask_D: BoolControl
    var mask_Dsh: BoolControl
    var mask_E: BoolControl
    var mask_F: BoolControl
    var mask_Fsh: BoolControl
    var mask_G: BoolControl
    var mask_Gsh: BoolControl
    var mask_A: BoolControl
    var mask_Ash: BoolControl
    var mask_B: BoolControl

    def get_namespace(self) -> String:
        return "chromasus"

    def __init__(out self, world: World):
        self.viscosity = Float64Control(0.1, 0.1, 20.0, 2)
        self.viscositychanged = Changed[Float64](self.viscosity.v)
        self.midi_offset = Float64Control(0.0, 0.0, 36.0)
        self.midi_offset_changed = Changed[Float64](self.midi_offset.v)
        self.chroma = FFTProcess[
                ChromaSusWindow[Self.n_chroma],
                ifft=False,
                input_window_shape=WindowType.hann
            ](
                world,
                process=ChromaSusWindow[Self.n_chroma](world,Self.widowsize, self.hopsize),
                window_size=Self.widowsize,
                hop_size=Self.hopsize
            )

        self.mask_C = BoolControl(True)
        self.mask_Csh = BoolControl(True)
        self.mask_D = BoolControl(True)
        self.mask_Dsh = BoolControl(True)
        self.mask_E = BoolControl(True)
        self.mask_F = BoolControl(True)
        self.mask_Fsh = BoolControl(True)
        self.mask_G = BoolControl(True)
        self.mask_Gsh = BoolControl(True)
        self.mask_A = BoolControl(True)
        self.mask_Ash = BoolControl(True)
        self.mask_B = BoolControl(True)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0) -> MFloat[2]:

        if self.viscositychanged.next(self.viscosity.v):
            self.chroma.get_process().set_lag_times(self.viscosity.v)

        _ = self.chroma.next(input.reduce_add())

        out = self.chroma.get_process().next(
            self.midi_offset.v,
            self.mask_C.v,
            self.mask_Csh.v,
            self.mask_D.v,
            self.mask_Dsh.v,
            self.mask_E.v,
            self.mask_F.v,
            self.mask_Fsh.v,
            self.mask_G.v,
            self.mask_Gsh.v,
            self.mask_A.v,
            self.mask_Ash.v,
            self.mask_B.v
            )

        return out

struct SoftClip(Modulable):
    comptime ovs: TimesOversampling = TimesOversampling.x2
    comptime ad_degree: Int = 3
    var world: World
    var pregain: LagFloat64Control
    var postgain: LagFloat64Control
    var compensated_pregain: LagFloat64Control
    var softclip: SoftClipAD[2,Self.ovs,Self.ad_degree]

    def get_namespace(self) -> String:
        return "softclip"

    def __init__(out self, world: World):
        self.world = world
        self.pregain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.postgain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.compensated_pregain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.softclip = SoftClipAD[2,Self.ovs,Self.ad_degree](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        cpg = self.compensated_pregain.next()
        inp = input * dbamp(self.pregain.next()) * dbamp(cpg)
        return self.softclip.next(inp) * dbamp(self.postgain.next()) * dbamp(-cpg)

struct HardClip(Modulable):
    comptime ovs: TimesOversampling = TimesOversampling.x2
    var world: World
    var pregain: LagFloat64Control
    var postgain: LagFloat64Control
    var compensated_pregain: LagFloat64Control
    var hardclip: HardClipAD[2,Self.ovs]

    def get_namespace(self) -> String:
        return "hardclip"

    def __init__(out self, world: World):
        self.world = world
        self.pregain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.postgain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.compensated_pregain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.hardclip = HardClipAD[2,Self.ovs](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        cpg = self.compensated_pregain.next()
        inp = input * dbamp(self.pregain.next()) * dbamp(cpg)
        return self.hardclip.next(inp) * dbamp(self.postgain.next()) * dbamp(-cpg)

struct Tanh(Modulable):
    comptime ovs: TimesOversampling = TimesOversampling.x2
    var world: World
    var pregain: LagFloat64Control
    var postgain: LagFloat64Control
    var compensated_pregain: LagFloat64Control
    var tanh: TanhAD[2,Self.ovs]

    def get_namespace(self) -> String:
        return "tanh"

    def __init__(out self, world: World):
        self.world = world
        self.pregain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.postgain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.compensated_pregain = LagFloat64Control(self.world, 0, 0.03, -24, 24)
        self.tanh = TanhAD[2,Self.ovs](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        cpg = self.compensated_pregain.next()
        inp = input * dbamp(self.pregain.next()) * dbamp(cpg)
        return self.tanh.next(inp) * dbamp(self.postgain.next()) * dbamp(-cpg)

struct Compress(Modulable):
    comptime ovs: TimesOversampling = TimesOversampling.none
    var world: World
    var threshold: Float64Control
    var ratio: Float64Control
    var attack: Float64Control
    var release: Float64Control
    var makeup: Float64Control
    var compressor: Compressor[2,Self.ovs]

    def get_namespace(self) -> String:
        return "compress"

    def __init__(out self, world: World):
        self.world = world
        self.threshold = Float64Control(0, -60, 0)
        self.ratio = Float64Control(1, 1, 20)
        self.attack = Float64Control(0.01, 0.001, 1)
        self.release = Float64Control(0.1, 0.001, 3)
        self.makeup = Float64Control(0, -24, 24)
        self.compressor = Compressor[2,Self.ovs](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        return self.compressor.next(
            input,
            self.threshold.v,
            self.ratio.v,
            self.attack.v,
            self.release.v
            ) * dbamp(self.makeup.v)

struct SamplesTimer(Copyable, Movable):
    var counter: Int
    var output: Int

    def __init__(out self):
        self.counter = 0
        self.output = 0

    def next(mut self, gate: Bool) -> Int:
        # when the gate goes low the output becomes the number of samples bewteen when it went high and when it went low
        if gate:
            self.counter += 1
        else:
            self.output = self.counter
            self.counter = 0

        return self.output

struct SecondsTimer(Copyable, Movable):
    var world: World
    var samples_counter: Int
    var output: Float64
    var rbd: RisingBoolDetector[]

    def __init__(out self, world: World):
        self.world = world
        self.samples_counter = 0
        self.output = 0.0
        self.rbd = RisingBoolDetector[]()

    def next(mut self, gate: Bool) -> Float64:
        # when the gate goes low the output becomes the number of samples bewteen when it went high and when it went low
        if gate:
            self.samples_counter += 1

        if self.rbd.next(not gate):
            self.output = Float64(self.samples_counter) / self.world[].sample_rate
            self.samples_counter = 0
            # print("falling edge detected, output seconds: ",self.output)

        # self.world[].print("seconds timer: gate: ",gate," samples counter: ",self.samples_counter," output: ",self.output)

        return self.output

struct Looper(Modulable):
    comptime interp: Interp = Interp.cubic
    comptime bufdur: Float64 = 8.0
    comptime epsilon: Float64 = 1e-10
    var world: World
    var buffer: SIMDCircleBuffer[2,Self.interp]
    var recording: BoolControl
    var recording_env: ASREnv
    var seconds_timer: SecondsTimer
    var phasor: Phasor[]
    var rate: Float64Control
    var random_rate: TrigControl

    def get_namespace(self) -> String:
        return "looper"
    
    def __init__(out self, world: World):
        self.world = world
        self.buffer = SIMDCircleBuffer[2,Self.interp](self.world, Self.bufdur)
        self.recording = BoolControl(False)
        self.recording_env = ASREnv(self.world)
        self.seconds_timer = SecondsTimer(self.world)
        self.phasor = Phasor[](self.world)
        self.rate = Float64Control(1.0, 0.25, 4.0, 2)
        self.random_rate = TrigControl(False)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:

        if self.random_rate.v:
            self.rate.v = exprand(0.25, 4.0)

        rec_env = self.recording_env.next(0.03,1,0.03,self.recording.v)

        dur_secs = self.seconds_timer.next(rec_env > 0.0) + Self.epsilon

        if rec_env > 0.0:
            self.buffer.write_next(input * rec_env)

        phs = self.phasor.next(self.rate.v / dur_secs,trig=not rec_env > 0.0) * (dur_secs / Self.bufdur)

        phs_start = (Self.bufdur - dur_secs) / Self.bufdur

        output = self.buffer.read_phase(phs_start + phs)

        return output

struct PShiftDel(Modulable):
    comptime interp: Interp = Interp.cubic
    comptime neg70db: Float64 = dbamp(-70.0)
    comptime max_delay: Float64 = 5.0
    var world: World
    var pink_noise: PinkNoise[2]
    var input_gate: BoolControl
    var input_gate_env: ASREnv
    var fb: MFloat[2]
    var delay: Delay[2,Self.interp]
    var delay_time: LagFloat64Control
    var pshift: PitchShift[2,WindowType.tri]
    var pitch_shift: Float64Control
    var dctrap: DCTrap[2]
    var feedback: LagFloat64Control

    def get_namespace(self) -> String:
        return "pshiftdel"
    
    def __init__(out self, world: World):
        self.world = world
        self.pink_noise = PinkNoise[2]()
        self.input_gate = BoolControl(False)
        self.input_gate_env = ASREnv(self.world)
        self.fb = 0.0
        self.delay = Delay[2,Self.interp](self.world, Self.max_delay)
        self.delay_time = LagFloat64Control(self.world,0.1, 0.03, 0.025, Self.max_delay, 2)
        self.pshift = PitchShift[2,WindowType.tri](self.world)
        self.pitch_shift = Float64Control(0.0, -12, 12)
        self.feedback = LagFloat64Control(self.world, -1, 0.03, -10.0, 6.0, 4)
        self.dctrap = DCTrap[2](self.world)

    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2]) -> MFloat[2]:
        dry = input * self.input_gate_env.next(0.03, 1.0, 0.03, self.input_gate.v)
        dry = dry + (self.pink_noise.next() * Self.neg70db)
        delay = dry + self.fb
        delay = self.delay.next(tanh(delay), self.delay_time.next())
        delay = self.pshift.next(in_sig=delay, grain_dur=0.12231220585509, pitch_ratio=2 ** (self.pitch_shift.v / 12.0))
        delay = self.dctrap.next(delay)
        self.fb = delay * dbamp(self.feedback.next())
        delay = tanh(delay)
        return delay