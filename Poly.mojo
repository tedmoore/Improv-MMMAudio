from instrument.ControlsHandler_module import *
from mmm_audio import *
from std.sys.intrinsics import _type_is_eq
from std.collections import Deque

struct Trig(Copyable, Movable):
    var state: Bool

    def __init__(out self, state: Bool = False):
        self.state = state

    def trig(mut self):
        self.state = True
    
    def next(mut self) -> Bool:
        if self.state:
            self.state = False
            return True
        return False

trait PolyVoiceT(Copyable,Movable,ImplicitlyDeletable):
    # initialize the voice
    def __init__(out self, world: World):...
    # update *all* the values for this voice
    def update_values(mut self, values: List[Float64]):...
    # start playing this voice
    def trig(mut self):...
    # get the samples out of this voice
    def next(mut self, input: MFloat[2]) -> MFloat[2]:...
    # see if this voice is running (aka. not available)
    def is_active(self) -> Bool:...

struct PolyT[T: PolyVoiceT, num: Int = 8, steal: Bool = True](Movable, Copyable):
    var world: World
    var voices: List[Self.T]
    var ch: ControlsHandler
    var history: Deque[Int]
    var trig_string: String
    var vals_to_pass: List[Float64]
    var all_string: String
    var is_active: List[Bool]
    var index_trig_strings: List[String]
    var index_values_strings: List[String]
    var index_values_trig_strings: List[String]

    def __init__(out self, world: World, namespace: String):
        self.world = world
        self.voices = List[Self.T]()
        self.is_active = List[Bool]()
        self.ch = ControlsHandler(world, namespace)
        self.history = Deque[Int]()
        self.trig_string = namespace + ".trig"
        self.vals_to_pass = List[Float64]()
        self.all_string = namespace + ".all"
        self.index_trig_strings = List[String]()
        self.index_values_strings = List[String]()
        self.index_values_trig_strings = List[String]()

        for i in range(Self.num):
            self.voices.append(Self.T(world))
            self.is_active.append(False)
            self.index_trig_strings.append(namespace + "." + String(i) + ".trig")
            self.index_values_strings.append(namespace + ".values" + String(i))
            self.index_values_trig_strings.append(namespace + "." + String(i) + ".values_trig")


    def values_trig(mut self, values: List[Float64]):
        self.vals_to_pass = values.copy()
        self.trig() 
    # ===================================================
    # trigger a voice, by finding an available voice and 
    # sending it the provided values
    # ===================================================
    def trig(mut self):
        for i in range(Self.num):
            if not self.voices[i].is_active():
                self.voices[i].update_values(self.vals_to_pass)
                self.voices[i].trig()
                self.is_active[i] = True

                # only need to keep track if stealing is enabled
                comptime if Self.steal:
                    try:
                        # oldest will be on the left
                        self.history.append(i)
                        if len(self.history) > Self.num:
                            _ = self.history.popleft()
                    except:
                        print("Error in PolyT trig: unable to append to history")
                return # to exit out and not move onto consider stealing
                    
        comptime if Self.steal:
            # if all voices are running, steal the oldest one
            try:
                oldest_index = self.history.popleft()
                self.voices[oldest_index].update_values(self.vals_to_pass)
                self.voices[oldest_index].trig()
                self.is_active[oldest_index] = True
                self.history.append(oldest_index)
            except:
                print("Error in PolyT trig: unable to steal voice")

    def initialize_ch(mut self):
        # ability to control parameters in each voice directly
        comptime t_types = reflect[Self.T].field_types()
        comptime t_names = reflect[Self.T].field_names()

        # =======================================================
        # if you want, you can control values in individual
        # voices by sending a message that will be:
        # "namespace.index.controlname" with the value to update
        # e.g. "mypoly.2.freq" with a value of 880.0
        # =======================================================
        comptime for i in range(reflect[Self.T].field_count()):
            # TODO: add other types
            if _type_is_eq[t_types[i], Float64Control]():
                control_name: String = materialize[t_names[i]]()
                for j in range(Self.num):
                    ref fc = __struct_field_ref(i, self.voices[j])
                    ref fc_param = rebind[Float64Control](fc)
                    self.ch.add_control(String(j) + "." + control_name, fc_param.v)

    def update_controls(mut self):
        self.ch.retrieve_from_python()

        # TRIGGER NEW AVAILABLE VOICE
        if self.ch.notify_update(self.trig_string, self.vals_to_pass):
            self.trig() # trig vals are used in this func.

        # UPDATE ALL VOICES TO THE SAME VALUES
        # if "namespace.all.values" is sent, update all voices with 
        # the provided values
        if self.ch.notify_update(self.all_string, self.vals_to_pass):
            # if the "all" message is sent, update all voices with the given values
            for i in range(Self.num):
                self.voices[i].update_values(self.vals_to_pass)

        # UPDATE VALUES OF A SPECIFIC VOICE WITHOUT TRIGGERING
        # if "namespace.index.values" is sent, update the corresponding voice
        # with the provided values but don't trigger it
        for i in range(Self.num):
            if self.ch.notify_update(self.index_values_strings[i], self.vals_to_pass):
                self.voices[i].update_values(self.vals_to_pass)

        # TRIGGER A SPECIFIC VOICE
        # if "namespace.index.trig" is sent, trigger the corresponding voice
        for i in range(Self.num):
            if self.ch.notify_update(self.index_trig_strings[i], self.vals_to_pass):
                self.voices[i].trig()
                self.is_active[i] = True

        # UPDATE VALUES AND TRIGGER A SPECIFIC VOICE
        # if "namespace.index.values_trig" is sent, update the corresponding voice with the provided values and trigger it
        for i in range(Self.num):
            if self.ch.notify_update(self.index_values_trig_strings[i], self.vals_to_pass):
                self.voices[i].update_values(self.vals_to_pass)
                self.voices[i].trig()
                self.is_active[i] = True
        
        self.ch.initialized = True

    # get the audio output from whatever voices are playing
    def next(mut self, input: MFloat[2] = 0.0) -> MFloat[2]:
        
        if not self.ch.initialized:
            self.initialize_ch()
        
        self.update_controls()

        out = MFloat[2](0.0, 0.0)
        comptime for i in range(Self.num):
            if self.is_active[i]:
                out += self.voices[i].next(input)
                self.is_active[i] = self.voices[i].is_active()

        return out
        